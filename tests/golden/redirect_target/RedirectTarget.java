class RedirectTarget {
    void leave(HttpServletResponse response, String next) throws Exception {
        response.sendRedirect(next);
    }

    void home(HttpServletResponse response, String next) throws Exception {
        response.sendRedirect("/home");
    }
}
