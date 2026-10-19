FROM nginx:stable-alpine
COPY deploy/production/nginx.conf /etc/nginx/conf.d/default.conf
COPY app/build/web/ /usr/share/nginx/html/
EXPOSE 80 443
