import re

with open('/Volumes/ExternoMacOs/GitHub/TransporteZCAdmin/supabase_backup_logic.sql') as f:
    content = f.read()

checks = {
    'manage_profile: uid = p_user_id::text': 'uid = p_user_id::text' in content,
    'get_complete_user_profile: LEFT JOIN clients': 'LEFT JOIN public.clients c ON p.id = c.uid::uuid AND c.email = p_email' in content,
    'get_complete_user_profile: COALESCE(c.id, 0)': 'COALESCE(c.id, 0) AS idclient' in content,
    'get_recharge_stats: v_route_ids': 'v_route_ids := public.get_current_user_route_ids()' in content,
    'get_recharge_stats: filter by route': "AND (public.is_admin() OR c.idroute = ANY(v_route_ids))" in content,
    # Wait the stats uses different context - let me check for the specific pattern
}

for name, ok in checks.items():
    print(f"{'✅' if ok else '❌'} {name}")

# Also check recharges_paginated
print()
print("--- get_recharges_paginated ---")
# Find all overloads
count = content.count('get_recharges_paginated(')
print(f"Overloads found: {count}")
