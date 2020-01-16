// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

const dartPageStyle = r'''
body {
  background-color: black;
  color: white;
  font-family: 'Open Sans', sans-serif;
  /* This allows very small files to be displayed lower than the very top of the
   * screen.
   */
  margin: 8px;
  padding: 0.5em;
}

h1 {
  font-size: 2.4em;
  font-weight: 600;
  margin: 0;
}

h2#unit-name {
  font-size: 1.2em;
  font-weight: 600;
  margin-bottom: 0;
}

.horizontal {
  display: flex;
}

.panel-heading {
  font-size: 18px;
  font-weight: 600;
  margin-top: 0;
  padding: 7px 7px 0 7px;
}

.nav-link, .region {
  cursor: pointer;
}

.nav-panel {
  background-color: #282b2e;
  flex: 1 1 300px;
  font-size: 14px;
  /* 10px to match exact top margin of .content.
   * 0.8em to pair with the -0.5em margin of .content, producing a net margin
   * between the two of 0.3em.
   */
  margin: 10px 0.8em 0 0;
}

.nav-inner {
  background-color: #282b2e;
  overflow: auto;
  padding: 0 0 7px 7px;
}

.fixed {
  position: fixed;
  top: 0;
}

.nav-inner .root {
  margin: 0;
}

.nav-inner ul {
  padding-left: 12px;
}
.nav-inner > ul {
  padding-left: 0;
  margin-top: 0;
}

.nav-inner li {
  list-style-type: none;
}

.nav-inner li.dir::before {
  content: "▼";
  font-size: 8px;
  padding-right: 5px;
}

.nav-inner li:not(.dir) {
  padding-left: 5px;
}

.nav-inner .nav-link {
  color: #33ccff;
  margin-left: 1em;
}

.nav-inner .selected-file {
  color: white;
  cursor: inherit;
  font-weight: 600;
  text-decoration: none;
}

.content {
  flex: 0 1 auto;
  font-family: monospace;
  /**
   * Left margin offsets the margin introduced by the absolutely positioned
   * child div.
   */
  margin: 10px 10px 10px -0.5em;
  position: relative;
  white-space: pre;
}

.code {
  left: 0.5em;
  /* Increase line height to make room for borders in non-nullable type
   * regions.
   */
  line-height: 1.3;
  min-height: 600px;
  padding-left: 62px;
  position: inherit;
  z-index: 100;
}

.code.hljs {
  background-color: inherit;
}

.code .welcome {
  font-family: 'Open Sans', sans-serif;
  font-size: 18px;
  margin-right: 62px;
}

.code .nav-link {
  color: inherit;
  text-decoration-line: none;
}

.code .nav-link:visited {
  color: inherit;
  text-decoration-line: none;
}

.code .nav-link:hover {
  text-decoration-line: underline;
  font-weight: 600;
}

.regions {
  background-color: #282b2e;
  padding: 0.5em 0 0.5em 0.5em;
  position: absolute;
  left: 0.5em;
  top: 0;
}

.regions table {
  border-spacing: 0;
}

.regions td {
  border: none;
  /* The content of the regions is not visible; the user instead will see the
   * highlighted copy of the content. */
  color: rgba(255, 255, 255, 0);
  line-height: 1.3;
  padding: 0;
  white-space: pre;
}

.regions td:empty:after {
  content: "\00a0";
}

.regions tr.highlight td:last-child {
  background-color: rgba(0, 0, 128, 0.5);
}

.regions td.line-no {
  border-right: solid #282b2e 2px;
  color: #999999;
  display: inline-block;
  padding-right: 4px;
  text-align: right;
  visibility: visible;
  width: 50px;
}

.regions tr.highlight td.line-no {
  border-right: solid #0000ff 2px;
}

.region {
  display: inline-block;
  position: relative;
  visibility: visible;
  z-index: 200;
}

.region.fix-region {
  /* Green means this region was added. */
  background-color: #ccffcc;
  color: #003300;
}

.region.non-nullable-type-region {
  background-color: rgba(0, 0, 0, 0.3);
  border-bottom: solid 2px #cccccc;
  /* Invisible text; use underlying highlighting. */
  color: rgba(0, 0, 0, 0);
  /* Reduce line height to make room for border. */
  line-height: 1;
}

/**
  * TODO(srawlins): Stop shipping tooltips as hidden DOM. Instead, request them
  * on each click.
  */
.region .tooltip {
  display: none;
}

.target {
  background-color: #FFFF99;
  color: black;
  position: relative;
  visibility: visible;
}

.info-panel {
  background-color: #282b2e;
  flex: 1 1 250px;
  font-size: 14px;
  margin: 10px 0;
}

.info-panel .info {
  font-size: 13px;
  padding: 7px;
}

.info-panel .info > :first-child {
  margin-top: 0;
}

.info-panel ul {
  padding-left: 18px;
}

.info-panel .nav-link {
  color: #33ccff;
}

.footer {
  padding: 8px 8px 100px 8px;
}
''';
