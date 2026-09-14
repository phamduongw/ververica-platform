\set ON_ERROR_STOP on

CREATE ROLE vvp LOGIN PASSWORD 'oracle_4U';

CREATE DATABASE "vvp-appmanager" OWNER vvp;
CREATE DATABASE "vvp-autopilot" OWNER vvp;
CREATE DATABASE "vvp-meta" OWNER vvp;
CREATE DATABASE "vvp-gateway" OWNER vvp;
CREATE DATABASE "vvp-advisor" OWNER vvp;
CREATE DATABASE "vvp-premise" OWNER vvp;
CREATE DATABASE "accesscontrol" OWNER vvp;

-- Only if global.k8sOperator.enabled=true later:
-- CREATE DATABASE "vvp-k8soperator" OWNER vvp;
