function setDownloadName(response, filename) {
    response.setHeader("Content-Disposition", filename);
}
function fixedDownloadName(response, filename) {
    response.setHeader("Content-Disposition", "attachment; filename=result.txt");
}
function checkedDownloadName(response, filename) {
    const checked = filename.replace(/[\r\n]/g, "");
    response.setHeader("Content-Disposition", checked);
}
