function setDownloadName(response: Response, filename: string) {
  response.setHeader("Content-Disposition", filename);
}

function fixedDownloadName(response: Response, filename: string) {
  response.setHeader("Content-Disposition", "attachment; filename=result.txt");
}

function checkedDownloadName(response: Response, filename: string) {
  const checked = filename.replace(/[\r\n]/g, "");
  response.setHeader("Content-Disposition", checked);
}
