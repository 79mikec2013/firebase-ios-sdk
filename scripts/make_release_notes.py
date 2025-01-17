#!/usr/bin/env python

# Copyright 2019 Google
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Converts github flavored markdown changelogs to release notes.
"""

import argparse
import re
import subprocess


NO_HEADING = 'PRODUCT HAS NO HEADING'


PRODUCTS = {
    'Firebase/Auth/CHANGELOG.md': '{{auth}}',
    'Firebase/Core/CHANGELOG.md': NO_HEADING,
    'Firebase/Database/CHANGELOG.md': '{{database}}',
    'Firebase/DynamicLinks/CHANGELOG.md': '{{ddls}}',
    'Firebase/InAppMessaging/CHANGELOG.md': '{{inapp_messaging}}',
    'Firebase/InstanceID/CHANGELOG.md': 'InstanceID',
    'Firebase/Messaging/CHANGELOG.md': '{{messaging}}',
    'Firebase/Storage/CHANGELOG.md': '{{storage}}',
    'Firestore/CHANGELOG.md': '{{firestore}}',
    'Functions/CHANGELOG.md': '{{cloud_functions}}',

    # 'Firebase/InAppMessagingDisplay/CHANGELOG.md': '?',
    # 'GoogleDataTransport/CHANGELOG.md': '?',
    # 'GoogleDataTransportCCTSupport/CHANGELOG.md': '?',
}


def main():
  local_repo = find_local_repo()

  parser = argparse.ArgumentParser(description='Create release notes.')
  parser.add_argument('--repo', '-r', default=local_repo,
                      help='Specify which GitHub repo is local.')
  parser.add_argument('--only', metavar='VERSION',
                      help='Convert only a specific version')
  parser.add_argument('--all', action='store_true',
                      help='Emits entries for all versions')
  parser.add_argument('changelog',
                      help='The CHANGELOG.md file to parse')
  args = parser.parse_args()

  if args.all:
    text = read_file(args.changelog)
  else:
    text = read_changelog_section(args.changelog, args.only)

  product = None
  if not args.all:
    product = PRODUCTS.get(args.changelog)

  renderer = Renderer(args.repo, product)
  translator = Translator(renderer)

  result = translator.translate(text)
  print(result)


def find_local_repo():
  url = subprocess.check_output(['git', 'config', '--get', 'remote.origin.url'])

  # ssh or https style URL
  m = re.match(r'^(?:git@github\.com:|https://github\.com/)(.*)\.git$', url)
  if m:
    return m.group(1)

  raise LookupError('Can\'t figure local repo from remote URL %s' % url)


CHANGE_TYPE_MAPPING = {
    'added': 'feature'
}


class Renderer(object):

  def __init__(self, local_repo, product):
    self.local_repo = local_repo
    self.product = product

  def heading(self, heading):
    if self.product:
      if self.product == NO_HEADING:
        return ''
      else:
        return '### %s\n' % self.product

    return heading

  def bullet(self, spacing):
    """Renders a bullet in a list.

    All bulleted lists in devsite are '*' style.
    """
    return '%s* ' % spacing

  def change_type(self, tag):
    """Renders a change type tag as the appropriate double-braced macro.

    That is "[fixed]" is rendered as "{{fixed}}".
    """
    tag = CHANGE_TYPE_MAPPING.get(tag, tag)
    return '{{%s}}' % tag

  def url(self, url):
    m = re.match(r'^(?:https:)?(//github.com/(.*)/issues/(\d+))$', url)
    if m:
      link = m.group(1)
      repo = m.group(2)
      issue = m.group(3)

      if repo == self.local_repo:
        text = '#' + issue
      else:
        text = repo + '#' + issue

      return '[%s](%s)' % (text, link)

    return url

  def local_issue_link(self, issue):
    """Renders a local issue link as a proper markdown URL.

    Transforms (#1234) into
    ([#1234](//github.com/firebase/firebase-ios-sdk/issues/1234)).
    """
    link = '//github.com/%s/issues/%s' % (self.local_repo, issue)
    return '([#%s](%s))' % (issue, link)

  def text(self, text):
    """Passes through any other text."""
    return text


class Translator(object):
  def __init__(self, renderer):
    self.renderer = renderer

  def translate(self, text):
    result = ''
    while text:
      for key in self.rules:
        rule = getattr(self, key)
        m = rule.match(text)
        if not m:
          continue

        callback = getattr(self, 'parse_' + key)
        callback_result = callback(m)
        result += callback_result

        text = text[len(m.group(0)):]
        break

    return result

  heading = re.compile(
      r'^#.*'
  )

  def parse_heading(self, m):
    return self.renderer.heading(m.group(0))

  bullet = re.compile(
      r'^(\s*)[*+-] '
  )

  def parse_bullet(self, m):
    return self.renderer.bullet(m.group(1))

  change_type = re.compile(
      r'\['           # opening square bracket
      r'(\w+)'        # tag word (like "feature" or "changed"
      r'\]'           # closing square bracket
      r'(?!\()'       # not followed by opening paren (that would be a link)
  )

  def parse_change_type(self, m):
    return self.renderer.change_type(m.group(1))

  url = re.compile(r'^(https?://[^\s<]+[^<.,:;"\')\]\s])')

  def parse_url(self, m):
    return self.renderer.url(m.group(1))

  local_issue_link = re.compile(
      r'\('           # opening paren
      r'#(\d+)'       # hash and issue number
      r'\)'           # closing paren
  )

  def parse_local_issue_link(self, m):
    return self.renderer.local_issue_link(m.group(1))

  text = re.compile(
      r'^[\s\S]+?(?=[(\[\n]|https?://|$)'
  )

  def parse_text(self, m):
    return self.renderer.text(m.group(0))

  rules = [
      'heading', 'bullet', 'change_type', 'url', 'local_issue_link', 'text'
  ]


def read_file(filename):
  """Reads the contents of the file as a single string."""
  with open(filename, 'r') as fd:
    return fd.read()


def read_changelog_section(filename, single_version=None):
  """Reads a single section of the changelog from the given filename.

  If single_version is None, reads the first section with a number in its
  heading. Otherwise, reads the first section with single_version in its
  heading.

  Args:
    - single_version: specifies a string to look for in headings.

  Returns:
    A string containing the heading and contents of the heading.
  """
  with open(filename, 'r') as fd:
    # Discard all lines until we see a heading that either has the version the
    # user asked for or any version.
    if single_version:
      initial_heading = re.compile(r'^#.*%s' % re.escape(single_version))
    else:
      initial_heading = re.compile(r'^#([^\d]*)\d')

    heading = re.compile(r'^#')

    initial = True
    result = []
    for line in fd:
      if initial:
        if initial_heading.match(line):
          initial = False
          result.append(line)

      else:
        if heading.match(line):
          break

        result.append(line)

    # Prune extra newlines
    while result and result[-1] == '\n':
      result.pop()

    return ''.join(result)


if __name__ == '__main__':
  main()
