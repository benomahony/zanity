function record(message) {
    console.log(message);
}
function structured(message) {
    console.log("request message: %s", message);
}
function cleaned(message) {
    const cleanedMessage = message.replace(/\n/g, " ");
    console.log(cleanedMessage);
}
