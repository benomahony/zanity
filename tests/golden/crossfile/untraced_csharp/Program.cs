var builder = WebApplication.CreateBuilder(args);
builder.Services.AddOpenTelemetry().WithTracing(tracing => tracing.AddSource("Orders"));
var app = builder.Build();

app.MapGet("/refunds", () => "refunded");
app.MapPost("/charges", Charges.Charge);

app.Run();
