function narrow(flag) {
    const onlyInside = 3;
    if (flag) {
        return onlyInside + 1;
    }
    return 0;
}
function direct(flag) {
    const value = 3;
    if (flag) {
        return value;
    }
    return value + 1;
}
function looped(items) {
    let seen = 0;
    for (const item of items) {
        seen += item;
    }
}
function closure() {
    const captured = 3;
    return () => captured;
}
function hoisted(flag) {
    var old = 3;
    if (flag) {
        return old;
    }
    return 0;
}
