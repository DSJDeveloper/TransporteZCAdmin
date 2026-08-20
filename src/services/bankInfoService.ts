import { supabase } from "./supabaseClient"

export interface BankInfo {
  id: number
  bank_name: string
  bank_code: string
  phone: string
  document_id: string
  status: number
  created_at?: string
}

export type BankInfoForm = Omit<BankInfo, "id" | "created_at">

export interface BankInfoName {
  id: number
  bank_name: string
  bank_code: string
}

interface RpcResult<T> {
  success: boolean
  data?: T
  message?: string
}

export async function getBankInfoList(): Promise<BankInfo[]> {
  const { data: raw, error } = await supabase.rpc("get_bank_info_list")
  if (error) throw error
  const result = raw as unknown as { success: boolean; data?: BankInfo[]; message?: string }
  if (!result.success) throw new Error(result.message ?? "Error al cargar la informacion bancaria")
  return result.data ?? []
}

export async function getBankInfoNames(): Promise<BankInfoName[]> {
  const { data: raw, error } = await supabase.rpc("get_bank_info_names")
  if (error) throw error
  const result = raw as unknown as { success: boolean; data?: BankInfoName[]; message?: string }
  if (!result.success) throw new Error(result.message ?? "Error al cargar los nombres bancarios")
  return result.data ?? []
}

export async function createBankInfo(input: BankInfoForm): Promise<BankInfo> {
  const { data: raw, error } = await supabase.rpc("manage_bank_info", {
    p_action: "create",
    p_id: null,
    p_bank_name: input.bank_name,
    p_bank_code: input.bank_code,
    p_phone: input.phone,
    p_document_id: input.document_id,
    p_status: input.status,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<BankInfo>
  if (!result.success) throw new Error(result.message ?? "Error al crear la informacion bancaria")
  return result.data as BankInfo
}

export async function updateBankInfo(id: number, input: Partial<BankInfoForm>): Promise<BankInfo> {
  const { data: raw, error } = await supabase.rpc("manage_bank_info", {
    p_action: "update",
    p_id: id,
    p_bank_name: input.bank_name ?? null,
    p_bank_code: input.bank_code ?? null,
    p_phone: input.phone ?? null,
    p_document_id: input.document_id ?? null,
    p_status: input.status ?? null,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<BankInfo>
  if (!result.success) throw new Error(result.message ?? "Error al actualizar la informacion bancaria")
  return result.data as BankInfo
}

export async function deleteBankInfo(id: number): Promise<void> {
  const { data: raw, error } = await supabase.rpc("manage_bank_info", {
    p_action: "delete",
    p_id: id,
    p_bank_name: null,
    p_bank_code: null,
    p_phone: null,
    p_document_id: null,
    p_status: null,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<never>
  if (!result.success) throw new Error(result.message ?? "Error al eliminar la informacion bancaria")
}
