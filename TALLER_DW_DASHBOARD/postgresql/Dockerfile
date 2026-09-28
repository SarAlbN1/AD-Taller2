FROM postgres:14

# Asignar variables de entorno
ENV POSTGRES_DB=retail_db
ENV POSTGRES_USER=lab_user
ENV POSTGRES_PASSWORD=lab_pass

# Copia los scripts de esquema y datos
COPY ./init/ /docker-entrypoint-initdb.d/
