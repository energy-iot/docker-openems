# Use Odoo 16.0 as the base image
FROM odoo:16.0

# Switch to root user to ensure we have permissions
USER root

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Switch back to odoo user (the default user in odoo image)
USER odoo

EXPOSE 8069

ENTRYPOINT ["/entrypoint.sh"]
CMD ["odoo"]
