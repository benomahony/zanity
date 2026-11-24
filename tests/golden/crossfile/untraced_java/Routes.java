import io.javalin.Javalin;

class Routes {
    void register(Javalin app, java.util.Map<String, String> prices) {
        app.get("/refunds", ctx -> ctx.result("refunded"));
        app.post("/charges", Handlers::charge);
        prices.get("small");
    }
}
