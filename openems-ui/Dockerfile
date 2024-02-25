FROM nginx

COPY m/ /usr/share/nginx/html/

RUN rm /etc/nginx/conf.d/default.conf

COPY nginx.conf /etc/nginx/conf.d/

EXPOSE 8089

CMD ["nginx", "-g", "daemon off;"]
