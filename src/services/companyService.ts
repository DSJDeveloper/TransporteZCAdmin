import { supabase } from './supabaseClient'

export interface InfoCompany {
  id: number
  name: string
  rif: string | null
  phone: string | null
  ticket:number
  tasa: number 
  account: string | null
  phoneAccount: string | null
  rifAccount: string | null
}

export const companyService = {
  async getInfoCompany(): Promise<InfoCompany | null> {
    const { data, error } = await supabase
      .from('company')
      .select('*')
      .maybeSingle()

    if (error) throw error
    return data
  },

  async updateCompany(payload: Partial<InfoCompany> & { id: number }): Promise<InfoCompany> {
    const { data, error } = await supabase
      .from('company')
      .upsert(payload)
      .select('*')
      .single()

    if (error) throw error
    return data
  },
}

export default companyService
