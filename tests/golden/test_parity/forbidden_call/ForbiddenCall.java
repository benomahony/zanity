import javax.script.ScriptEngine;

class ForbiddenCall {
    Object run(ScriptEngine engine, String script) throws Exception {
        return engine.eval(script);
    }

    Object read(ScriptEngine engine, String name) {
        return engine.get(name);
    }
}
