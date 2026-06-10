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
  /* Driver-specific fields (only set when role = 'driver') */
  photo_url?: string | null;
  unit_id?: number;
  unit_name?: string;
  unit_number?: string;
  unit_plate?: string;
  unit_status?: number;
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
  "Access denied": "Acceso denegado. Solo administradores pueden ingresar.",
  "not_admin": "Acceso denegado. Solo administradores pueden ingresar.",
};

function friendlyError(err: unknown): string {
  const msg = (err as { message?: string })?.message ?? "";
  for (const [key, friendly] of Object.entries(ERROR_MESSAGES)) {
    if (msg.includes(key)) return friendly;
  }
  return "Error al iniciar sesión. Intenta de nuevo."+msg ;
}

/**
 * @description Force-remove any Supabase auth tokens from localStorage.
 * Defense in depth: supabase.auth.signOut() may not always clear storage
 * (e.g. network error mid-flight).
 */
function clearSupabaseSession() {
  const toRemove: string[] = []
  for (let i = 0; i < localStorage.length; i++) {
    const key = localStorage.key(i)
    if (key?.startsWith('sb-') && key.endsWith('-auth-token')) {
      toRemove.push(key)
    }
  }
  toRemove.forEach((k) => localStorage.removeItem(k))
}

export const useAuthStore = defineStore("auth", () => {
  const user = ref<ClientProfile | null>(null);
  const session = ref<any>(null);
  const loading = ref(false);
  const error = ref<string | null>(null);
  const initialized = ref(false);

  const idclient = computed(() => user.value?.idclient ?? 0);

  async function signOutAndClear() {
    try {
      await supabase.auth.signOut()
    } catch {
      // Network failure — still force-clear local tokens below
    }
    clearSupabaseSession()
    user.value = null
    session.value = null
  }

  async function enforceAdminOrReject() {
    if (user.value && user.value.role !== 'admin') {
      await signOutAndClear()
      throw new Error('not_admin')
    }
  }

  async function login(identifier: string, password: string) {
    loading.value = true;
    error.value = null;

    try {
      let emailToAuth = identifier;

      if (!identifier.includes("@")) {
        const { data: foundEmail, error: rpcError } = await supabase.rpc(
          "get_email_by_username",
          {
            username_input: identifier,
          },
        );

        if (rpcError || !foundEmail) {
          throw new Error("El nombre de usuario no existe.");
        }

        emailToAuth = foundEmail;
      }

      const { data:authData, error: authError } =
        await supabase.auth.signInWithPassword({
          email: emailToAuth,
          password: password,
          options: {
            data: {
              app_source: "admin-app",
            },
          } as any,
        });
      if (authError) throw authError;

      // Fetch profile FIRST — only set session if role is admin
      await fetchProfile(authData.user.id, authData.user.email ?? "");
      if (user.value && user.value.role === 'admin') {
        session.value = authData.user;
      } else {
        await signOutAndClear()
        throw new Error('not_admin')
      }
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
          p_uuid: uuid,
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
      /**
       * Cross-tab session destruction: when the last tab is closed,
       * useTabTracker sets a flag in localStorage. If we detect it here
       * and this is a fresh tab (not a refresh), destroy the session.
       */
      const loadCount = parseInt(sessionStorage.getItem('load_count') || '0')
      const isRefresh = loadCount > 1
      if (!isRefresh) {
        const lastClosed = localStorage.getItem('last_tab_closed')
        if (lastClosed) {
          const elapsed = Date.now() - parseInt(lastClosed)
          if (elapsed < 60_000) {
            await signOutAndClear()
            localStorage.removeItem('last_tab_closed')
            return
          }
          localStorage.removeItem('last_tab_closed')
        }
      }

      const {
        data: { session: s },
        error,
      } = await supabase.auth.getSession();
      if (error) throw error;

      // Only restore session after verifying the user is admin
      if (s?.user) {
        await fetchProfile(s.user.id, s.user.email ?? "");
        if (user.value && user.value.role === 'admin') {
          session.value = s.user;
        } else {
          // Non-admin or profile fetch failed — wipe everything
          await signOutAndClear()
        }
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
    await signOutAndClear()
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
