# Build the browser-side PDF/ZIP processor from the committed lockfile.
FROM node:22-alpine AS r2-ui
WORKDIR /build/tools/r2-import-ui
COPY tools/r2-import-ui/package.json tools/r2-import-ui/package-lock.json ./
RUN npm ci
COPY tools/r2-import-ui/ ./
RUN npm run build
RUN node -e "const fs=require('fs'),p=require('path');for(const f of fs.readdirSync('node_modules',{recursive:true})){if(/^(license|copying|notice)/i.test(p.basename(f))&&fs.statSync(p.join('node_modules',f)).isFile()){const t=p.join('/build/public/r2-import/third-party-licenses',f);fs.mkdirSync(p.dirname(t),{recursive:true});fs.copyFileSync(p.join('node_modules',f),t);}}"

# Reuse the official runtime and its Perl/native dependencies.
FROM difegue/lanraragi:v.0.9.81
LABEL org.opencontainers.image.title="LANraragi R2" \
      org.opencontainers.image.description="LANraragi 0.9.81 with configurable R2 direct uploads and range-based reading" \
      org.opencontainers.image.licenses="MIT"
WORKDIR /home/koyomi/lanraragi
COPY --chown=koyomi:koyomi lib/ ./lib/
COPY --chown=koyomi:koyomi templates/ ./templates/
COPY --chown=koyomi:koyomi public/js/ ./public/js/
COPY --chown=koyomi:koyomi public/css/ ./public/css/
COPY --chown=koyomi:koyomi locales/ ./locales/
COPY --chown=koyomi:koyomi tools/openapi.yaml ./tools/openapi.yaml
COPY --from=r2-ui --chown=koyomi:koyomi /build/public/r2-import/ ./public/r2-import/
COPY COPYING ./COPYING
