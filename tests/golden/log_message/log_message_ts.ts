function record(message: string) {
  console.log(message);
}

function structured(message: string) {
  console.log("request message: %s", message);
}

function cleaned(message: string) {
  const cleanedMessage = message.replace(/\n/g, " ");
  console.log(cleanedMessage);
}
