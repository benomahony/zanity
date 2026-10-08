def trust(fragment):
    return mark_safe(fragment)


def fixed(fragment):
    return mark_safe("<strong>Ready</strong>")


def escaped(fragment):
    checked = bleach.clean(fragment)
    return mark_safe(checked)
