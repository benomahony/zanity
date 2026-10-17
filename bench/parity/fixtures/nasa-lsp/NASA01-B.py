def depth(node: dict) -> int:
    assert node is not None, "node must exist"
    assert "children" in node, "node must list its children"
    return 1 + max((depth(child) for child in node["children"]), default=0)
