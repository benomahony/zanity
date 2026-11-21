import JavaScriptCore

func run(_ context: JSContext, _ code: String) -> JSValue? {
    return context.evaluateScript(code)
}

func read(_ context: JSContext, _ name: String) -> JSValue? {
    return context.objectForKeyedSubscript(name)
}
