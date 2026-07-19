// Preferencias de Zen Browser para permitir la firma con AutoFirma.
// Se copia como `user.js` al perfil, y Zen lo cargará automáticamente.
//
// Estas prefs controlan:
//   - Que el navegador delegue el protocolo afirma:// al sistema (xdg-open).
//   - Que confíe en los CA del trust store del sistema operativo.

user_pref("network.protocol-handler.external.afirma", true);   // Permitir handler externo
user_pref("network.protocol-handler.warn-external.afirma", false); // No preguntar al usuario
user_pref("network.protocol-handler.expose.afirma", false);    // No gestionar internamente (delegate to OS)
user_pref("security.enterprise_roots.enabled", true);          // Importar CA del sistema (incluye Autofirma ROOT)