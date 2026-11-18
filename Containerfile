FROM public.ecr.aws/docker/library/node:24-alpine

WORKDIR /app
COPY --chown=node:node server.js index.html ./

ENV HOST=0.0.0.0
USER node
EXPOSE 4173

CMD ["node", "server.js"]
