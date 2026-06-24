import { defineStore } from "pinia";
import { ref } from "vue";
import ticketsService, {
  type Movimiento,
  type TicketCobroItem,
} from "../services/ticketsService";
import { useAuthStore } from "./authStore";
import { formatCurrency } from "../utils/formatters";

export const useTicketStore = defineStore("ticket", () => {
  // Estado
  const balance = ref(0);
  const tasa = ref(0);
  const movimientos = ref<Movimiento[]>([]);
  const loading = ref({
    balance: false,
    tasa: false,
    movimientos: false,
    procesarPago: false,
  });
  const error = ref<string | null>(null);
  const filtros = ref({
    fechaInicio: "",
    fechaFin: "",
  });

  // Acciones
  const cargarBalance = async (idclient: number | null) => {
    const auth = useAuthStore();

    if (!auth.validateSession()) {
      error.value = auth.error;
      return false;
    }
    loading.value.balance = true;
    error.value = null;
    try {
      const saldo = await ticketsService.getSaldoDisponible(
        idclient ?? auth.idclient,
      );
      balance.value = saldo;
    } catch (err) {
      error.value = "Error al cargar el saldo";
      console.error(err);
    } finally {
      loading.value.balance = false;
    }
  };

  const getInfoCompany = async () => {};
  const cargarMovimientos = async () => {
    const auth = useAuthStore();

    if (!auth.validateSession()) {
      error.value = auth.error;
      return false;
    }

    loading.value.movimientos = true;
    error.value = null;

    try {
      if (auth.user?.role == "student") {
        const resultData = await ticketsService.getMovimientosUnificado(
          auth.idclient,
          filtros.value.fechaInicio,
          filtros.value.fechaFin,
        );
        movimientos.value = resultData.history;
        await cargarBalance(null);
      } else {
        const resultData = await ticketsService.getMovimientosTransacciones(
          auth.idclient,
          filtros.value.fechaInicio,
          filtros.value.fechaFin,
        );
        movimientos.value = resultData.history;
        balance.value = resultData.balance;
      }
    } catch (err) {
      error.value = "Error al cargar los movimientos";
      console.error(err);
      return false;
    } finally {
      loading.value.movimientos = false;
    }
    return true;
  };

  const procesarPago = async (
    monto: number,
    method: string,
    date: string,
    rate: number,
    reference: string | null,
    imageFile: File | null,
  ) => {
    const auth = useAuthStore();

    if (!auth.validateSession()) {
      error.value = auth.error;
      return false;
    }
    loading.value.procesarPago = true;
    error.value = null;
    try {
      var ldtares = await ticketsService.procesarPago({
        clientId: auth.idclient,
        amount: monto,
        method: method,
        ref: reference, // Referencia bancaria opcional
        tasa: rate, // Tasa de cambio si manejan multimoneda
        date: date, // Formato YYYY-MM-DD
        imageFile: imageFile, // Archivo físico capturado del input HTML
        createdBy: auth.user!.uuid,
      });
      if (ldtares.success) {
        await cargarBalance(null);
        await cargarMovimientos();
      } else {
        error.value = ldtares.message;
        return false;
      }
    } catch (err) {
      error.value = "Error al procesar el pago";
      console.error(err);
      return false;
    } finally {
      loading.value.procesarPago = false;
    }
    return true;
  };

  const addTickets = async (idclient: number, ticketCount: number) => {
    const auth = useAuthStore()

    if (!auth.validateSession()) {
      error.value = auth.error
      return false
    }

    loading.value.procesarPago = true
    error.value = null

    try {
      const result = await ticketsService.addTicketsToClient(idclient, ticketCount, auth.idclient)
      if (result.success) {
        return true
      } else {
        error.value = result.message ?? "Error al agregar tickets"
        return false
      }
    } catch (err) {
      error.value = (err as Error).message || "Error al agregar tickets"
      console.error(err)
      return false
    } finally {
      loading.value.procesarPago = false
    }
  }

  const cobrarTicketsBulk = async (listaTickets: TicketCobroItem[]) => {
    const auth = useAuthStore();

    // 1. Validar sesión antes de disparar la petición
    if (!auth.validateSession()) {
      error.value = auth.error;
      return false;
    }

    loading.value.procesarPago = true;
    error.value = null;

    try {
      // 2. Enviamos el array completo y el ID del usuario/cajero que opera
      const ldtares = await ticketsService.chargeTicketsBulk(
        listaTickets,
        auth.idclient, // El ID del creador/cajero logueado
      );

      // 3. Evaluar la respuesta unificada del backend
      if (ldtares.success) {
        // Aquí puedes mapear 'ldtares.details' si necesitas actualizar saldos locales en caliente
        // await cargarBalance();
        // await cargarMovimientos();
        return true;
      } else {
        error.value = ldtares.message;
        return false;
      }
    } catch (err) {
      // Fallo crítico de red o de código
      error.value = "Error al procesar el lote de pagos";
      console.error(err);
      return false;
    } finally {
      loading.value.procesarPago = false;
    }
  };

  // Getters
  const getBalanceFormatted = () => {
    return balance.value.toFixed(2);
  };

  const getMovimientosPorStatus = (status: number) => {
    return movimientos.value.filter((mov) => mov.status === status);
  };

  const getTasa = async () => {
    loading.value.tasa = true;
    try {
      const response = await fetch(
        "https://ve.dolarapi.com/v1/dolares/oficial",
      );
      if (!response.ok) throw new Error("Error al consultar la API");

      const data = await response.json();
      // Asignamos el valor numérico de la tasa (del BCV) a nuestra variable reactiva
      // Nota: pydolarve suele devolver el campo principal como 'promedio' o 'price'
      tasa.value = data.promedio || data.price || 0;
    } catch (error) {
      console.error("No se pudo obtener la tasa oficial:", error);
      // Puedes colocar una tasa de respaldo (fallback) por si la API se cae
      tasa.value = 40.0;
    } finally {
      loading.value.tasa = false;
    }
  };

  // Reset store
  const resetStore = () => {
    balance.value = 0;
    movimientos.value = [];
    loading.value = {
      balance: false,
      tasa: false,
      movimientos: false,
      procesarPago: false,
    };
    error.value = null;
    filtros.value = {
      fechaInicio: "",
      fechaFin: "",
    };
  };

  return {
    // Estado
    balance,
    movimientos,
    loading,
    error,
    filtros,

    // Acciones
    cargarBalance,
    cargarMovimientos,
    procesarPago,
    resetStore,
    addTickets,
    cobrarTicketsBulk,
    // Getters
    getBalanceFormatted,
    getMovimientosPorStatus,
    getTasa,
    tasa,
  };
});
