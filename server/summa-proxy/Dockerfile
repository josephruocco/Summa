# Portable container for the Summa proxy. Works on Fly.io, Railway, Render
# (Docker runtime), Cloud Run, or any container host. Render's native Node
# runtime doesn't need this -- see README.
FROM node:20-alpine
WORKDIR /app

# Install deps first for layer caching.
COPY package.json package-lock.json* ./
RUN npm install --omit=dev

COPY server.js ./

# Hosts inject their own PORT; the server reads process.env.PORT.
ENV PORT=8787
EXPOSE 8787
CMD ["node", "server.js"]
