FROM nginx

RUN mkdir /usr/share/nginx/html/m
COPY m /usr/share/nginx/html/m

RUN rm /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/conf.d/
EXPOSE 8089
CMD ["nginx", "-g", "daemon off;"]
