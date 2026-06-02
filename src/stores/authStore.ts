import { defineStore } from "pinia";
import { ref, computed } from "vue";
import { supabase } from "../services/supabaseClient";
export type UserRole = "admin" | "student" | "driver";
export interface ClientProfile {
  id: number;
  idclient: number;
  name: string;
  email: string;
  phone: string | null;
  saldo: number;
  created_at: string;
  role: UserRole;
  uuid: string;
}

export interface AuthStoreState {
  user: ClientProfile | null;
  session: any;
  loading: boolean;
  error: string | null;
  initialized: boolean;
  idclient: number | null;
}

const ERROR_MESSAGES: Record<string, string> = {
  "Invalid login credentials":
    "Credenciales inválidas. Revisa tu usuario y contraseña.",
  "Email not confirmed":
    "Correo electrónico no confirmado. Revisa tu bandeja de entrada.",
  "Rate limit exceeded": "Demasiados intentos. Intenta de nuevo más tarde.",
  "Invalid email": "El formato del correo no es válido.",
  "Email rate limit exceeded":
    "Demasiados intentos. Espera un momento e intenta de nuevo.",
};

function friendlyError(err: unknown): string {
  const msg = (err as { message?: string })?.message ?? "";
  for (const [key, friendly] of Object.entries(ERROR_MESSAGES)) {
    if (msg.includes(key)) return friendly;
  }
  return "Error al iniciar sesión. Intenta de nuevo."+msg ;
}

export const useAuthStore = defineStore("auth", () => {
  const user = ref<ClientProfile | null>(null);
  const session = ref<any>(null);
  const loading = ref(false);
  const error = ref<string | null>(null);
  const initialized = ref(false);

  const idclient = computed(() => user.value?.idclient ?? 0);

  async function login(identifier: string, password: string) {
    loading.value = true;
    error.value = null;

    try {
      let emailToAuth = identifier;

      // 1. Validar si lo que ingresó el usuario NO es un correo (es un username)
      if (!identifier.includes("@")) {
        // Llamamos a la función de SQL que creamos en el paso 1
        const { data: foundEmail, error: rpcError } = await supabase.rpc(
          "get_email_by_username",
          {
            username_input: identifier,
          },
        );

        if (rpcError || !foundEmail) {
          throw new Error("El nombre de usuario no existe.");
        }

        // Si lo encuentra, reemplazamos el identificador por el correo real
        emailToAuth = foundEmail;
      }

      // 2. Ejecutar el login tradicional de Supabase con el correo obtenido
      // const { data, error: authError } = await supabase.auth.signInWithPassword(
      //   {
      //     email: emailToAuth,
      //     password,
      //   },
      // );

      // if (authError) throw authError;
      // if (!data.user) throw new Error("No se pudo obtener el usuario.");

      const { data:authData, error: authError } =
        await supabase.auth.signInWithPassword({
          email: emailToAuth,
          password: password,
          options: {
            // Rompemos temporalmente el tipado estricto para que TS te deje pasar la propiedad
            data: {
              app_source: "admin-app",
            },
          } as any,
        });
      if (authError) throw authError;

      // const appMetadata = authData.user?.app_metadata;

      // if (appMetadata && appMetadata.login_blocked) {
      //   await supabase.auth.signOut();
      //   throw new Error(`Acceso denegado: ${appMetadata.block_reason}`);
      // }


      session.value = authData.user;
      await fetchProfile(authData.user.id, authData.user.email ?? "");
    } catch (err) {
      error.value = friendlyError(err);
      console.error(err);
      user.value = null;
      session.value = null;
    } finally {
      loading.value = false;
    }
  }

  async function fetchProfile(uuid: string, userEmail: string) {
    // 🛡️ Validación preventiva de seguridad
    if (!uuid || !userEmail) {
      console.error("❌ No se puede cargar el perfil: UUID o Email ausentes.", {
        uuid,
        userEmail,
      });
      user.value = null;
      return;
    }

    try {
      const { data, error: rpcError } = await supabase.rpc(
        "get_complete_user_profile",
        {
          p_uuid: uuid, // Enviamos el string limpio
          p_email: userEmail,
        },
      );

      if (rpcError) throw rpcError;

      if (!data || Object.keys(data).length === 0) {
        console.warn(
          "⚠️ No se encontró coincidencia para este perfil en la base de datos.",
        );
        user.value = null;
        return;
      }

      user.value = data as ClientProfile;
    } catch (err) {
      console.error("Error crítico en RPC get_complete_user_profile:", err);
      user.value = null;
    }
  }

  async function initAuth() {
    loading.value = true;
    try {
      const {
        data: { session: s },
        error,
      } = await supabase.auth.getSession();
      if (error) throw error;
      if (s?.user) {
        session.value = s.user;
        await fetchProfile(s.user.id, s.user.email ?? "");
      }
    } catch (err) {
      console.error("Error al restaurar sesión:", err);
      user.value = null;
      session.value = null;
    } finally {
      loading.value = false;
      initialized.value = true;
    }
  }

  async function logout() {
    await supabase.auth.signOut();
    user.value = null;
    session.value = null;
    error.value = null;
  }

  function validateSession() {
    if (!idclient) {
      error.value = "Sesión no disponible";
      return false;
    }
    error.value = "";
    return true;
  }

  return {
    user,
    session,
    loading,
    error,
    initialized,
    idclient,
    login,
    fetchProfile,
    initAuth,
    logout,
    validateSession,
  };
});
