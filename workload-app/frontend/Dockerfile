# syntax=docker/dockerfile:1

# Build stage - Node.js 24 for Vite build (requires Node >= 20.19)
FROM mcr.microsoft.com/azurelinux/base/nodejs:24 AS build
WORKDIR /app

# Copy package files and install ALL dependencies (build needs devDependencies)
COPY package*.json ./
RUN npm install

# Copy source and build with Vite
COPY . ./
RUN npm run build

# Runtime stage - nginx 1.28 to serve SPA
FROM mcr.microsoft.com/azurelinux/base/nginx:1.28 AS runtime
WORKDIR /usr/share/nginx/html

# Install gettext for envsubst (environment variable substitution)
RUN tdnf install -y gettext && tdnf clean all

# Remove default nginx content
RUN rm -rf /usr/share/nginx/html/*

# Copy custom nginx config and entrypoint
COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY nginx/default.conf.template /etc/nginx/conf.d/default.conf.template
COPY nginx/entrypoint.sh /entrypoint.sh

# Copy built SPA from build stage
COPY --from=build /app/dist ./

# Make entrypoint executable
RUN chmod +x /entrypoint.sh

# Expose port 80
EXPOSE 80

# Use entrypoint script to substitute environment variables at runtime
ENTRYPOINT ["/entrypoint.sh"]
