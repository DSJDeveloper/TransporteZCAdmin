---
name: Logistics Core
colors:
  surface: '#f8f9ff'
  surface-dim: '#cbdbf5'
  surface-bright: '#f8f9ff'
  surface-container-lowest: '#ffffff'
  surface-container-low: '#eff4ff'
  surface-container: '#e5eeff'
  surface-container-high: '#dce9ff'
  surface-container-highest: '#d3e4fe'
  on-surface: '#0b1c30'
  on-surface-variant: '#424656'
  inverse-surface: '#213145'
  inverse-on-surface: '#eaf1ff'
  outline: '#727687'
  outline-variant: '#c2c6d8'
  surface-tint: '#0054d6'
  primary: '#0050cb'
  on-primary: '#ffffff'
  primary-container: '#0066ff'
  on-primary-container: '#f8f7ff'
  inverse-primary: '#b3c5ff'
  secondary: '#565e74'
  on-secondary: '#ffffff'
  secondary-container: '#dae2fd'
  on-secondary-container: '#5c647a'
  tertiary: '#006645'
  on-tertiary: '#ffffff'
  tertiary-container: '#008259'
  on-tertiary-container: '#e1ffec'
  error: '#ba1a1a'
  on-error: '#ffffff'
  error-container: '#ffdad6'
  on-error-container: '#93000a'
  primary-fixed: '#dae1ff'
  primary-fixed-dim: '#b3c5ff'
  on-primary-fixed: '#001849'
  on-primary-fixed-variant: '#003fa4'
  secondary-fixed: '#dae2fd'
  secondary-fixed-dim: '#bec6e0'
  on-secondary-fixed: '#131b2e'
  on-secondary-fixed-variant: '#3f465c'
  tertiary-fixed: '#6ffbbe'
  tertiary-fixed-dim: '#4edea3'
  on-tertiary-fixed: '#002113'
  on-tertiary-fixed-variant: '#005236'
  background: '#f8f9ff'
  on-background: '#0b1c30'
  surface-variant: '#d3e4fe'
typography:
  headline-lg:
    fontFamily: Inter
    fontSize: 32px
    fontWeight: '700'
    lineHeight: 40px
    letterSpacing: -0.02em
  headline-md:
    fontFamily: Inter
    fontSize: 24px
    fontWeight: '600'
    lineHeight: 32px
    letterSpacing: -0.01em
  headline-sm:
    fontFamily: Inter
    fontSize: 20px
    fontWeight: '600'
    lineHeight: 28px
  body-lg:
    fontFamily: Inter
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 24px
  body-md:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: '400'
    lineHeight: 20px
  label-md:
    fontFamily: Inter
    fontSize: 12px
    fontWeight: '600'
    lineHeight: 16px
    letterSpacing: 0.05em
  headline-lg-mobile:
    fontFamily: Inter
    fontSize: 24px
    fontWeight: '700'
    lineHeight: 32px
rounded:
  sm: 0.125rem
  DEFAULT: 0.25rem
  md: 0.375rem
  lg: 0.5rem
  xl: 0.75rem
  full: 9999px
spacing:
  base: 4px
  xs: 8px
  sm: 12px
  md: 16px
  lg: 24px
  xl: 32px
  gutter: 16px
  margin-mobile: 16px
  margin-desktop: 40px
---

## Brand & Style

The design system is engineered for the high-velocity, high-reliability world of transport and logistics. The brand personality is **utilitarian, dependable, and precise**, focusing on reducing the cognitive load for operators who interact with complex data under time pressure. 

The visual style is **Corporate Modern with a Minimalist lens**. It prioritizes extreme legibility and functional whitespace over decorative elements. By stripping away non-essential styling, the system ensures that critical information—status updates, timestamps, and route details—remains the primary focus of the user experience.

## Colors

This design system utilizes a professional palette anchored in a high-clarity blue. 

- **Primary Blue:** Used for primary actions, active navigation states, and key highlights. It is chosen for its association with trust and professional service.
- **Surface & Backgrounds:** The system uses a "Clean White" (#FFFFFF) for primary surfaces and a very light grey (#F8FAFC) for secondary backgrounds to create subtle separation between content blocks.
- **Neutrals:** A scale of cool grays is used for borders (#E2E8F0), secondary text (#64748B), and disabled states.
- **Functional Colors:** Success (Green) for completed shipments, Warning (Amber) for delays, and Error (Red) for critical alerts follow standard industry patterns to ensure instant recognition.

## Typography

The system relies exclusively on **Inter**, a typeface designed for screen legibility and functional clarity. 

- **Hierarchy:** Use bold weights for headlines to create clear entry points. Body text remains at a medium weight for maximum readability in data-heavy lists.
- **Data Display:** For numerical data (tracking numbers, timestamps), use tabular figures to ensure alignment in tables and lists.
- **Labels:** Small, uppercase labels with increased letter-spacing are used for metadata headers to distinguish them from actionable content.

## Layout & Spacing

The system follows a **Fluid Grid** model based on an 8px spacing rhythm. 

- **Grid:** A 12-column system is used for desktop, collapsing to a 4-column system for mobile devices.
- **Padding:** Generous internal padding (minimum 16px) is required within cards to prevent visual clutter.
- **Density:** While the overall system is "airy," data tables may switch to a "compact" mode (8px cell padding) for professional users who need to view many rows of logistics data simultaneously.

## Elevation & Depth

To maintain a minimalist aesthetic while providing clear hierarchy, the design system uses **Tonal Layering** supplemented by **Ambient Shadows**.

- **Depth Levels:**
    - **Level 0 (Background):** Solid white or very light grey (#F8FAFC).
    - **Level 1 (Cards/Surface):** White background with a soft, diffused shadow (0px 4px 12px rgba(0, 0, 0, 0.05)) and a subtle 1px border (#E2E8F0).
    - **Level 2 (Modals/Popovers):** Higher contrast shadow to suggest temporary interaction (0px 10px 25px rgba(0, 0, 0, 0.1)).

Avoid heavy black shadows; depth should feel like light catching the edge of a physical folder.

## Shapes

The shape language is **Soft**. 

Consistent corner radii are used to make the interface feel modern and approachable without appearing too "playful." 
- **Standard UI (Buttons, Inputs):** 0.25rem (4px).
- **Large Elements (Cards, Containers):** 0.5rem (8px).
- **Indicators (Status Badges):** Fully rounded (pill-shaped) to distinguish them from interactive buttons.

## Components

### Buttons
- **Primary:** Solid primary blue with white text. High contrast, clear call to action.
- **Secondary:** Outlined blue with a white background. Used for secondary tasks like "Export" or "Filter."
- **Ghost:** No border or background; blue text. Used for low-priority actions in headers.

### Input Fields (PrimeVue Style)
- Fields use a 1px border (#CBD5E1) that transitions to primary blue on focus. 
- Floating labels or clear top-aligned labels are required. 
- Error states must include both a red border and a helper icon for accessibility.

### Cards
- The primary container for logistics data. 
- Must include a clear header area and a structured body. 
- Information inside cards should be grouped using the 8px spacing scale (e.g., Origin and Destination grouped closely, separated from the Timestamp).

### Chips & Status Badges
- Used for shipment status (e.g., "In Transit," "Delivered").
- Use low-saturation background tints with high-saturation text of the same hue (e.g., Light Green background with Dark Green text).

### Lists
- Interaction-heavy lists should use "Zebra Striping" or subtle border dividers to help the eye track across rows of shipment data.