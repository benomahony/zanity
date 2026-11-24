var builder = WebApplication.CreateBuilder(args);
builder.Services.AddOpenTelemetry().WithTracing(tracing => tracing.AddSource("Orders").AddAspNetCoreInstrumentation());
var app = builder.Build();

app.MapGet("/refunds", () => "refunded");

app.Run();
