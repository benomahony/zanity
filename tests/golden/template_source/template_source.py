def render(source, context):
    return jinja2.Template(source).render(context)


def render_fixed(source, context):
    return jinja2.Template("Hello {{ name }}").render(context)


def render_selected(context):
    source = "Hello {{ name }}"
    return jinja2.Template(source).render(context)
