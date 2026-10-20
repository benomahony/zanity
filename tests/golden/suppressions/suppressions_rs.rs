#![allow(dead_code)]

#[allow(clippy::too_many_arguments, unused)]
fn wide() {}

#[expect(unused_variables)]
fn later() {}

#[cfg_attr(test, allow(unused))]
fn tested() {}

#[derive(Debug)]
struct Plain;

#[cfg(test)]
fn honest() {}
