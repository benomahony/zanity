use std::collections::HashMap;
use std::rc::Rc;

struct Scene {
    nodes: Vec<Box<Node>>,
    shared: HashMap<u32, Rc<Node>>,
    flat: Vec<Node>,
    shapes: Vec<Box<dyn Shape>>,
}

struct Node {
    id: u32,
}

trait Shape {}
