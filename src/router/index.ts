import { createRouter, createWebHistory } from "vue-router";
import { useAuthStore } from "../stores/authStore";

const router = createRouter({
  history: createWebHistory(),
  routes: [
    {
      path: "/login",
      name: "login",
      component: () => import("../pages/Login.vue"),
    },
    {
      path: "/",
      component: () => import("../layouts/AppLayout.vue"),
      meta: { requiresAuth: true },
      children: [
        {
          path: "",
          name: "home",
          component: () => import("../pages/Home.vue"),
        },
        {
          path: "clientes",
          name: "clientes",
          component: () => import("../pages/Clientes.vue"),
        },
        {
          path: "unidades",
          name: "unidades",
          component: () => import("../pages/Unidades.vue"),
        },
        {
          path: "recargas",
          name: "recargas",
          component: () => import("../pages/HistorialRecargas.vue"),
        },
        {
          path: "movimientos",
          name: "movimientos",
          component: () => import("../pages/HistorialMovimientos.vue"),
        },
        {
          path: "configuracion",
          name: "configuracion",
          component: () => import("../pages/Configuracion.vue"),
        },
        {
          path: "configuracion/info-bancaria",
          name: "info-bancaria",
          component: () => import("../pages/InfoBancaria.vue"),
        },
        {
          path: "configuracion/horarios",
          name: "horarios",
          component: () => import("../pages/Horarios.vue"),
        },
        {
          path: "configuracion/rutas",
          name: "rutas",
          component: () => import("../pages/Rutas.vue"),
        },
        {
          path: "configuracion/usuarios",
          name: "usuarios",
          component: () => import("../pages/Usuarios.vue"),
        },
        {
          path: "analisis-mensual",
          name: "analisis-mensual",
          component: () => import("../pages/AnalisisMensual.vue"),
        },
      ],
    },
  ],
});

router.beforeEach(async (to, _, next) => {
  const auth = useAuthStore();
  if (!auth.initialized) await auth.initAuth();
  if (to.meta.requiresAuth && !auth.session) return next({ name: "login" });
  if (to.name === "login" && auth.session) return next({ name: "home" });
  next();
});

export default router;
