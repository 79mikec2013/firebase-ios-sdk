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

#include <memory>
#include <vector>

#include "Firestore/core/src/firebase/firestore/core/order_by.h"
#include "benchmark/benchmark.h"

using firebase::firestore::core::OrderBy;
using firebase::firestore::core::Direction;
using firebase::firestore::immutable::AppendOnlyList;
using firebase::firestore::model::FieldPath;

static void BM_Baseline(benchmark::State& state) {
  int64_t len = state.range(0);

  for (auto _ : state) {
    std::vector<OrderBy> order_bys;
    for (int64_t i = 0; i < len; i++) {
      auto field = FieldPath::FromDotSeparatedString("a.b");
      auto order_by = OrderBy(std::move(field), Direction::Ascending);
      order_bys.push_back(std::move(order_by));
    }
  }
}
BENCHMARK(BM_Baseline)
    ->Arg(1 << 0)
    ->Arg(1 << 1)
    ->Arg(1 << 2)
    ->Arg(1 << 3)
    ->Arg(1 << 4)
    ->Arg(1 << 5);

static void BM_SimpleCopy(benchmark::State& state) {
  int64_t len = state.range(0);

  for (auto _ : state) {
    std::vector<OrderBy> order_bys;
    for (int64_t i = 0; i < len; i++) {
      auto field = FieldPath::FromDotSeparatedString("a.b");
      auto order_by = OrderBy(std::move(field), Direction::Ascending);

      // This simulates AppendingTo at master
      std::vector<OrderBy> updated = order_bys;
      updated.push_back(std::move(order_by));
      order_bys = updated;
    }
  }
}
BENCHMARK(BM_SimpleCopy)
    ->Arg(1 << 0)
    ->Arg(1 << 1)
    ->Arg(1 << 2)
    ->Arg(1 << 3)
    ->Arg(1 << 4)
    ->Arg(1 << 5);

static void BM_SharedCopy(benchmark::State& state) {
  int64_t len = state.range(0);

  for (auto _ : state) {
    auto order_bys = std::make_shared<std::vector<OrderBy>>();
    for (int64_t i = 0; i < len; i++) {
      auto field = FieldPath::FromDotSeparatedString("a.b");
      auto order_by = OrderBy(std::move(field), Direction::Ascending);

      // This simulates AppendingTo at master
      auto updated = std::make_shared<std::vector<OrderBy>>(*order_bys);
      updated->push_back(std::move(order_by));
      order_bys = updated;
    }
  }
}
BENCHMARK(BM_SharedCopy)
    ->Arg(1 << 0)
    ->Arg(1 << 1)
    ->Arg(1 << 2)
    ->Arg(1 << 3)
    ->Arg(1 << 4)
    ->Arg(1 << 5);

static void BM_AppendOnlyList(benchmark::State& state) {
  int64_t len = state.range(0);

  for (auto _ : state) {
    AppendOnlyList<OrderBy> order_bys;
    for (int64_t i = 0; i < len; i++) {
      auto field = FieldPath::FromDotSeparatedString("a.b");
      auto order_by = OrderBy(std::move(field), Direction::Ascending);

      order_bys = order_bys.push_back(std::move(order_by));
    }
  }
}
BENCHMARK(BM_AppendOnlyList)
    ->Arg(1 << 0)
    ->Arg(1 << 1)
    ->Arg(1 << 2)
    ->Arg(1 << 3)
    ->Arg(1 << 4)
    ->Arg(1 << 5);
