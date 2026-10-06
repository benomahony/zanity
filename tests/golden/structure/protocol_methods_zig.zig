fn forward(x: u32) u32 {
    return target(x);
}

pub fn format(self: Session, writer: anytype) !void {
    return self.render(writer);
}
