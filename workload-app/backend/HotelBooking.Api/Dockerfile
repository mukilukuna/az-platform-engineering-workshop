# syntax=docker/dockerfile:1

# Build stage - .NET 10 SDK
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Copy csproj and restore dependencies (cached layer)
COPY HotelBooking.Api.csproj ./
RUN dotnet restore

# Copy source and build
COPY . ./
RUN dotnet publish -c Release -o /app/publish --no-restore

# Runtime stage - ASP.NET 10 runtime (minimal)
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app

# Copy published app from build stage
COPY --from=build /app/publish ./

# Expose port (matches Container Apps configuration)
EXPOSE 8080

# Set ASP.NET to listen on port 8080
ENV ASPNETCORE_URLS=http://+:8080

ENTRYPOINT ["dotnet", "HotelBooking.Api.dll"]
