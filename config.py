import os
from dotenv import load_dotenv

load_dotenv()

LDAP_SERVER = "ldaps://ldap.fis.epn.ec"  
BASE_DN = "dc=fis,dc=epn,dc=ec"
KERBEROS_REALM = "FIS.EPN.EC"
APP_HOST = "0.0.0.0"
APP_PORT = 5000

CA_CERT_PATH = "/opt/pki/ca/ca.crt"

SECRET_KEY = os.environ["SECRET_KEY"]
LDAP_ADMIN_DN = "cn=admin,dc=fis,dc=epn,dc=ec"
LDAP_ADMIN_PASSWORD = os.environ["LDAP_ADMIN_PASSWORD"]

KADMIN_KEYTAB = "/opt/miniidm/shared/svc-admin.keytab"
KADMIN_PRINCIPAL = f"svc-admin/admin@{KERBEROS_REALM}"