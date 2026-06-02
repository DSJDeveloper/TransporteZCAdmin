import { createApp } from 'vue'
import { createPinia } from 'pinia'
import PrimeVue from 'primevue/config'
import Aura from '@primevue/themes/aura'
import Button from 'primevue/button'
import Avatar from 'primevue/avatar'
import DatePicker from 'primevue/datepicker'
import InputText from 'primevue/inputtext'
import Password from 'primevue/password'
import Toast from 'primevue/toast'
import ToastService from 'primevue/toastservice'
import router from './router'
import App from './App.vue'


import './assets/main.css'
import './assets/variables.css'
import 'primeicons/primeicons.css'

const app = createApp(App)

app.use(createPinia())
app.use(router)
app.component('Button', Button)
app.component('Avatar', Avatar)
app.component('DatePicker', DatePicker)
app.component('InputText', InputText)
app.component('Password', Password)
app.component('Toast', Toast)
app.use(ToastService)
app.use(PrimeVue, {
  theme: {
    preset: Aura,
    options: {
      darkModeSelector: false,
    },
  },
})

app.mount('#app')
