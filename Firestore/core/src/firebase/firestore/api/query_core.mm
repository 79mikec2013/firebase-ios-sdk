/*
 * Copyright 2019 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "Firestore/core/src/firebase/firestore/api/query_core.h"

#include <future>  // NOLINT(build/c++11)
#include <memory>
#include <utility>

#import "Firestore/Source/Core/FSTFirestoreClient.h"

#include "Firestore/core/src/firebase/firestore/api/firestore.h"
#include "Firestore/core/src/firebase/firestore/core/field_filter.h"
#include "Firestore/core/src/firebase/firestore/core/filter.h"
#include "Firestore/core/src/firebase/firestore/model/field_value.h"
#include "absl/algorithm/container.h"

NS_ASSUME_NONNULL_BEGIN

namespace firebase {
namespace firestore {
namespace api {

namespace util = firebase::firestore::util;
using core::AsyncEventListener;
using core::Bound;
using core::Direction;
using core::EventListener;
using core::FieldFilter;
using core::Filter;
using core::ListenOptions;
using core::QueryListener;
using core::ViewSnapshot;
using model::DocumentKey;
using model::FieldPath;
using model::FieldValue;
using model::ResourcePath;
using util::Status;
using util::StatusOr;

using Operator = Filter::Operator;

Query::Query(core::Query query, std::shared_ptr<Firestore> firestore)
    : firestore_{std::move(firestore)}, query_{std::move(query)} {
}

bool operator==(const Query& lhs, const Query& rhs) {
  return lhs.firestore() == rhs.firestore() && lhs.query() == rhs.query();
}

size_t Query::Hash() const {
  return util::Hash(firestore_.get(), query());
}

void Query::GetDocuments(Source source, QuerySnapshot::Listener&& callback) {
  if (source == Source::Cache) {
    [firestore_->client() getDocumentsFromLocalCache:*this
                                            callback:std::move(callback)];
    return;
  }

  ListenOptions options(
      /*include_query_metadata_changes=*/true,
      /*include_document_metadata_changes=*/true,
      /*wait_for_sync_when_online=*/true);

  class ListenOnce : public EventListener<QuerySnapshot> {
   public:
    ListenOnce(Source source, QuerySnapshot::Listener&& listener)
        : source_(source), listener_(std::move(listener)) {
    }

    void OnEvent(StatusOr<QuerySnapshot> maybe_snapshot) override {
      if (!maybe_snapshot.ok()) {
        listener_->OnEvent(std::move(maybe_snapshot));
        return;
      }

      QuerySnapshot snapshot = std::move(maybe_snapshot).ValueOrDie();

      // Remove query first before passing event to user to avoid user actions
      // affecting the now stale query.
      ListenerRegistration registration =
          registration_promise_.get_future().get();
      registration.Remove();

      if (snapshot.metadata().from_cache() && source_ == Source::Server) {
        listener_->OnEvent(Status{
            FirestoreErrorCode::Unavailable,
            "Failed to get documents from server. (However, these documents "
            "may exist in the local cache. Run again without setting source to "
            "FirestoreSourceServer to retrieve the cached documents.)"});
      } else {
        listener_->OnEvent(std::move(snapshot));
      }
    };

    void Resolve(ListenerRegistration&& registration) {
      registration_promise_.set_value(std::move(registration));
    }

   private:
    Source source_;
    QuerySnapshot::Listener listener_;

    std::promise<ListenerRegistration> registration_promise_;
  };

  auto listener = absl::make_unique<ListenOnce>(source, std::move(callback));
  auto listener_unowned = listener.get();

  ListenerRegistration registration =
      AddSnapshotListener(std::move(options), std::move(listener));

  listener_unowned->Resolve(std::move(registration));
}

ListenerRegistration Query::AddSnapshotListener(
    ListenOptions options, QuerySnapshot::Listener&& user_listener) {
  // Convert from ViewSnapshots to QuerySnapshots.
  class Converter : public EventListener<ViewSnapshot> {
   public:
    Converter(Query* parent, QuerySnapshot::Listener&& user_listener)
        : firestore_(parent->firestore()),
          query_(parent->query()),
          user_listener_(std::move(user_listener)) {
    }

    void OnEvent(StatusOr<ViewSnapshot> maybe_snapshot) override {
      if (!maybe_snapshot.status().ok()) {
        user_listener_->OnEvent(maybe_snapshot.status());
        return;
      }

      ViewSnapshot snapshot = std::move(maybe_snapshot).ValueOrDie();
      SnapshotMetadata metadata(snapshot.has_pending_writes(),
                                snapshot.from_cache());

      QuerySnapshot result(firestore_, query_, std::move(snapshot),
                           std::move(metadata));

      user_listener_->OnEvent(result);
    }

   private:
    std::shared_ptr<Firestore> firestore_;
    core::Query query_;
    QuerySnapshot::Listener user_listener_;
  };
  auto view_listener =
      absl::make_unique<Converter>(this, std::move(user_listener));

  // Call the view_listener on the user Executor.
  auto async_listener = AsyncEventListener<ViewSnapshot>::Create(
      firestore_->client().userExecutor, std::move(view_listener));

  std::shared_ptr<QueryListener> query_listener =
      [firestore_->client() listenToQuery:this->query()
                                  options:options
                                 listener:async_listener];

  return ListenerRegistration(firestore_->client(), std::move(async_listener),
                              std::move(query_listener));
}

Query Query::Filter(FieldPath field_path,
                    Filter::Operator op,
                    FieldValue field_value,
                    const std::function<std::string()>& type_describer) const {
  if (field_path.IsKeyFieldPath()) {
    if (op == Filter::Operator::ArrayContains) {
      ThrowInvalidArgument(
          "Invalid query. You can't perform arrayContains queries on document "
          "ID since document IDs are not arrays.");
    }
    if (field_value.type() == FieldValue::Type::String) {
      const std::string& document_key = field_value.string_value();
      if (document_key.empty()) {
        ThrowInvalidArgument(
            "Invalid query. When querying by document ID you must provide a "
            "valid document ID, but it was an empty string.");
      }
      if (!query_.IsCollectionGroupQuery() &&
          document_key.find('/') != std::string::npos) {
        ThrowInvalidArgument(
            "Invalid query. When querying a collection by document ID you must "
            "provide a plain document ID, but '%s' contains a '/' character.",
            document_key);
      }
      ResourcePath path =
          query_.path().Append(ResourcePath::FromString(document_key));
      if (!DocumentKey::IsDocumentKey(path)) {
        ThrowInvalidArgument(
            "Invalid query. When querying a collection group by document ID, "
            "the value provided must result in a valid document path, but '%s' "
            "is not because it has an odd number of segments.",
            path.CanonicalString());
      }
      field_value = FieldValue::FromReference(firestore_->database_id(),
                                              DocumentKey{path});
    } else if (field_value.type() != FieldValue::Type::Reference) {
      ThrowInvalidArgument(
          "Invalid query. When querying by document ID you must provide a "
          "valid string or DocumentReference, but it was of type: %s",
          type_describer());
    }
  }

  std::shared_ptr<FieldFilter> filter =
      FieldFilter::Create(field_path, op, field_value);
  ValidateNewFilter(*filter);

  return Wrap(query_.AddingFilter(std::move(filter)));
}

Query Query::OrderBy(FieldPath fieldPath, bool descending) const {
  return OrderBy(fieldPath, Direction::FromDescending(descending));
}

Query Query::OrderBy(FieldPath fieldPath, Direction direction) const {
  ValidateNewOrderByPath(fieldPath);
  if (query_.start_at()) {
    ThrowInvalidArgument("Invalid query. You must not specify a starting point "
                         "before specifying the order by.");
  }
  if (query_.end_at()) {
    ThrowInvalidArgument("Invalid query. You must not specify an ending point "
                         "before specifying the order by.");
  }
  return Wrap(
      query_.AddingOrderBy(core::OrderBy(std::move(fieldPath), direction)));
}

Query Query::Limit(int32_t limit) const {
  if (limit <= 0) {
    ThrowInvalidArgument(
        "Invalid Query. Query limit (%s) is invalid. Limit must be positive.",
        limit);
  }
  return Wrap(query_.WithLimit(limit));
}

Query Query::StartAt(Bound bound) const {
  return Wrap(query_.StartingAt(std::move(bound)));
}

Query Query::EndAt(Bound bound) const {
  return Wrap(query_.EndingAt(std::move(bound)));
}

namespace {

constexpr Operator kArrayOps[] = {
    Operator::ArrayContains,
};

}

void Query::ValidateNewFilter(const class Filter& filter) const {
  if (filter.IsAFieldFilter()) {
    const auto& field_filter = static_cast<const FieldFilter&>(filter);

    if (field_filter.IsInequality()) {
      const FieldPath* existing_inequality = query_.InequalityFilterField();
      const FieldPath* new_inequality = &filter.field();

      if (existing_inequality && *existing_inequality != *new_inequality) {
        ThrowInvalidArgument(
            "Invalid Query. All where filters with an inequality (lessThan, "
            "lessThanOrEqual, greaterThan, or greaterThanOrEqual) must be on "
            "the same field. But you have inequality filters on '%s' and '%s'",
            existing_inequality->CanonicalString(),
            new_inequality->CanonicalString());
      }

      const FieldPath* first_order_by_field = query_.FirstOrderByField();
      if (first_order_by_field) {
        ValidateOrderByField(*first_order_by_field, filter.field());
      }

    } else {
      // You can have at most 1 disjunctive filter and 1 array filter. Check if
      // the new filter conflicts with an existing one.
      Operator filter_op = field_filter.op();
      bool is_array_op = absl::c_linear_search(kArrayOps, filter_op);

      if (is_array_op && query_.HasArrayContainsFilter()) {
        ThrowInvalidArgument("Invalid Query. Queries only support a single "
                             "arrayContains filter.");
      }
    }
  }
}

void Query::ValidateNewOrderByPath(const FieldPath& fieldPath) const {
  if (!query_.FirstOrderByField()) {
    // This is the first order by. It must match any inequality.
    const FieldPath* inequalityField = query_.InequalityFilterField();
    if (inequalityField) {
      ValidateOrderByField(fieldPath, *inequalityField);
    }
  }
}

void Query::ValidateOrderByField(const FieldPath& orderByField,
                                 const FieldPath& inequalityField) const {
  if (orderByField != inequalityField) {
    ThrowInvalidArgument(
        "Invalid query. You have a where filter with an inequality "
        "(lessThan, lessThanOrEqual, greaterThan, or greaterThanOrEqual) on "
        "field '%s' and so you must also use '%s' as your first queryOrderedBy "
        "field, but your first queryOrderedBy is currently on field '%s' "
        "instead.",
        inequalityField.CanonicalString(), inequalityField.CanonicalString(),
        orderByField.CanonicalString());
  }
}

}  // namespace api
}  // namespace firestore
}  // namespace firebase

NS_ASSUME_NONNULL_END
