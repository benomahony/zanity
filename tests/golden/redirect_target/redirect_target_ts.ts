function leave(response: Response, next: string) {
  response.redirect(next);
}

function home(response: Response, next: string) {
  response.redirect("/home");
}
