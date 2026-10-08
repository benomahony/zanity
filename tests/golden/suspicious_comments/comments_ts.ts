/* BUG: this accepts expired credentials. */
function authenticate(token: string): boolean {
  return token.length > 0;
}

// The debugger and bugfix metadata are not defect markers.
function quiet(): boolean {
  return true;
}
