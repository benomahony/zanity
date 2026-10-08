from flask import redirect


def leave(next_url):
    return redirect(next_url)


def home(next_url):
    return redirect("/home")
