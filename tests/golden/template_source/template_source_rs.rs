fn render(tera: &Tera, source: &str, context: &Context) {
    tera.render_str(source, context);
}

fn register(tera: &mut Tera, name: &str, source: &str) {
    tera.add_raw_template(name, source);
}

fn render_fixed(tera: &Tera, source: &str, context: &Context) {
    tera.render_str("Hello {{ name }}", context);
}

fn render_selected(tera: &Tera, context: &Context) {
    let source = "Hello {{ name }}";
    tera.render_str(source, context);
}
