FROM mcr.microsoft.com/dotnet/aspnet:9.0
ENV OTEL_DOTNET_AUTO_HOME=/otel-dotnet-auto
COPY out/ /app
ENTRYPOINT ["/otel-dotnet-auto/instrument.sh", "dotnet", "/app/Orders.dll"]
