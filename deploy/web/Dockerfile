FROM nginx:stable-alpine
COPY deploy/web/nginx.conf /etc/nginx/conf.d/default.conf
COPY app/build/web/ /usr/share/nginx/html/
EXPOSE 80
