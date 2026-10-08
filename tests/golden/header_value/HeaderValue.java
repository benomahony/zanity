class HeaderValue {
    void setDownloadName(HttpServletResponse response, String filename) {
        response.setHeader("Content-Disposition", filename);
    }

    void fixedDownloadName(HttpServletResponse response, String filename) {
        response.setHeader("Content-Disposition", "attachment; filename=result.txt");
    }

    void checkedDownloadName(HttpServletResponse response, String filename) {
        String checked = filename.replace("\r", "").replace("\n", "");
        response.setHeader("Content-Disposition", checked);
    }
}
