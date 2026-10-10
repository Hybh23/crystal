# CLAUDE.md — كرستال (CRYSTAL)

متجر إلكتروني لبيع الإكسسوارات **بالجملة** في ليبيا. واجهة عربية RTL بالكامل، والعملة دينار ليبي (د.ل).

## التقنية

- **صفحات HTML ثابتة فقط**: لا يوجد build ولا package.json ولا framework. كل صفحة ملف مستقل فيه `<style>` و`<script>` داخليين.
- **Backend**: Supabase (قاعدة بيانات + Auth + Storage) عبر `@supabase/supabase-js@2` من jsDelivr.
  - `SUPABASE_URL` و`SUPABASE_ANON_KEY` (مفتاح publishable عام) مكررين حرفيًا في رأس سكربت كل صفحة. أي تغيير لازم يتطبق على كل الملفات.
  - الحماية الحقيقية لازم تكون في **RLS ودوال RPC على Supabase**. منطق الواجهة ما يكفيش.
- **الإشعارات**: OneSignal Web SDK v16 (انظر القسم الخاص بيها تحت).
- **الاستضافة**: ملف `_headers` (صيغة Cloudflare Pages / Netlify) يجبر `Content-Type: text/html; charset=utf-8`.
- الخطوط: Tajawal للعربي و Inter للأرقام والإنجليزي (الكلاس `.en`).
- التصميم: متغيرات CSS على `:root` مكررة في كل صفحة (`--primary:#A9822A` ذهبي، `--bg:#FBF9F4`).

## هيكل الملفات

### صفحات الزبون
| الملف | الوظيفة |
|---|---|
| `index.html` | الرئيسية: شبكة المنتجات، فلترة بالأقسام و"ترند"، بحث، مفضلة، إضافة سريعة للسلة، وجرس الإشعارات |
| `product.html?id=` | تفاصيل المنتج: الصور، اختيار اللون (إجباري لو المنتج عنده ألوان مفعّلة)، والكمية |
| `cart.html` | السلة وفرض الحد الأدنى للطلب |
| `checkout.html` | إتمام الطلب لضيف أو زبون مسجّل، اختيار المدينة (سعر التوصيل)، وطريقة الدفع |
| `order-confirmation.html?order=&total=&method=` | تأكيد الطلب، وزر واتساب لإرسال إيصال التحويل |
| `order-status.html?order=` | تتبّع الطلب عبر RPC `get_order_status_public` |
| `customer-login.html?redirect=` | دخول أو تسجيل برقم الهاتف |
| `account.html` | حساب الزبون وطلباته السابقة |
| `favorites.html` | المفضلة (IDs محفوظة في localStorage) |
| `contact.html` | روابط التواصل (هاتف، واتساب، انستقرام، تيك توك، فيسبوك، الخريطة) |

### صفحات الإدارة
| الملف | الوظيفة |
|---|---|
| `admin-login.html` | دخول الأدمن بالإيميل وكلمة السر (Supabase Auth) |
| `admin.html` | لوحة التحكم، تفعيل إشعارات الطلبات الجديدة، ونقطة بداية الـ PWA (`manifest.json`) |
| `admin-orders.html` | إدارة الطلبات وتغيير الحالة عبر RPC `admin_update_order_status` |
| `admin-products.html` | تعديل السعر، التوفر، علامة "آخر القطع"، والحذف (المنتج المرتبط بطلبات ما ينحذفش، يتوقف توفره بس) |
| `admin-add-product.html` | إضافة منتج: صور تترفع لـ bucket اسمه `product-images`، وألوان مفصولة بفاصلة `,` أو `،` |
| `admin-cities.html` | المدن وأسعار التوصيل |
| `admin-reports.html` | إحصائيات تنحسب في المتصفح (الطلبات الملغاة مستبعدة من المبيعات) |
| `admin-backup.html` | تنزيل نسخة JSON من كل الجداول |

### ملفات أخرى
- `OneSignalSDKWorker.js`: service worker تبع OneSignal. **لازم يقعد في الجذر وبهذا الاسم بالضبط** (تاريخ git فيه إعادة تسمية ذهاب وإياب، فلا تغيّر اسمه).
- `manifest.json`: PWA للوحة الإدارة (`start_url: /admin.html`).
- `icon-192.png`, `icon-512.png`: أيقونات المتجر والـ manifest. `icon-admin-192.png`, `icon-admin-512.png`: أيقونات صفحات الإدارة.
- `shop-front.jpg`: صورة واجهة المحل المعروضة في `contact.html`.
- `README.md`: وصف مختصر، والتفاصيل هنا.

## قواعد العمل المهمة

### 1. الحد الأدنى للطلب: 300 د.ل
- يُحسب على **إجمالي المنتجات فقط** (من غير التوصيل).
- `cart.html`: الثابت `MIN_ORDER = 300`. لو الإجمالي أقل، زر المتابعة يتقفل وتظهر رسالة بالمبلغ الناقص.
- `checkout.html`: نفس الثابت `MIN_ORDER = 300`. لو الإجمالي أقل، `init()` يرجّع الزبون لـ `cart.html`.
- الثابت `MIN_ORDER` معرّف في الملفين، ونص رسالة السلة ياخذ قيمته منه. لو تغيّر الحد، عدّل الملفين. الفرض في الواجهة فقط، والأفضل يتحقق منه السيرفر داخل دوال `create_*_order`.

### 2. وحدة البيع: قطعة أو دستة
- العمود `products.sale_unit` قيمته `"piece"` (قطعة) أو `"dozen"` (دستة)، وأي قيمة غير `dozen` تُعرض "قطعة".
- **السعر هو سعر الوحدة نفسها**، يعني سعر الدستة كاملة لو المنتج بالدستة. والكمية تُعدّ بالوحدة: `quantity: 3` على منتج بالدستة معناها 3 دستات. ما فيش أي تحويل لقطع.
- الوحدة تتخزن مع كل عنصر في السلة (`sale_unit`) وتنحفظ في الطلب كـ `sale_unit_snapshot`.

### 3. الإشعارات عبر OneSignal
- `appId: "c8318950-edb6-4899-bc3b-19189079f1d0"`، والـ SDK هو `OneSignalSDK.page.js` v16، والتهيئة عن طريق `window.OneSignalDeferred`.
- **الزبون**:
  - `index.html`: زر الجرس (`toggleBell`) يطلب الإذن أو يدير `optOut`.
  - `checkout.html`: ياخذ `OneSignal.User.PushSubscription.id` ويبعثه كـ `p_push_subscription_id` لدالة إنشاء الطلب، عشان السيرفر يقدر يبعث تحديثات حالة الطلب لهذا الجهاز.
- **الأدمن**: `admin.html` يحفظ الـ subscription id في جدول `admin_push_subscriptions` (upsert على `subscription_id`) عشان توصله إشعارات الطلبات الجديدة.
- **إرسال الإشعارات نفسه ما يصيرش من هذا الريبو**. يصير من جهة Supabase (trigger أو Edge Function أو webhook)، والكود هذا مش موجود هنا.

## البيانات وتدفق الطلب

- **localStorage**: `crystal_cart` يحتوي `[{product_id, name, price, sale_unit, color, quantity, image}]`، و`crystal_favorites` يحتوي `[product_id]`.
- **جداول Supabase المستخدمة**: `categories`, `products`, `product_images`, `product_colors`, `cities`, `customers`, `orders`, `order_items`, `order_status_history`, `admin_push_subscriptions`.
- **دوال RPC**: `create_guest_order`, `create_customer_order` (ترجّع `result_order_number` و`result_grand_total`)، و`admin_update_order_status`، و`get_order_status_public`.
- **حالات الطلب**: الطلب يبدأ بـ `pending_verification` في حالة التحويل المصرفي (يتحول لـ `new` بعد "تأكيد الدفع" مع `payment_status = verified`)، أو بـ `new` في حالة الدفع عند الاستلام. بعدها يمشي `prepared` ثم `out_for_delivery` ثم `delivered`. الإلغاء `cancelled` متاح من أي حالة قبل التسليم.
- **طرق الدفع**: `cod` و`bank_transfer`. بيانات الحساب المصرفي مكتوبة في `checkout.html`، والإيصال يتبعت على واتساب `218920900011`.
- **حسابات الزبائن**: الدخول برقم الهاتف، والرقم يتحول لإيميل وهمي `09XXXXXXXX@crystalstore.ly` في Supabase Auth، وبعدها يتعمل صف في `customers`.
- **أرقام الهاتف الليبية**: نفس الـ regex في `checkout.html` و`customer-login.html`: `^(?:\+218|00218|0)9[1-4][0-9]{7}$` (091 إلى 094 بس، وما فيش رقم ليبي يبدا بـ 095). لو تغيّر، غيّره في الاثنين.

## قواعد أمان لازم تتبع

- **صلاحية الإدارة**: كل صفحة `admin-*` فيها `isCustomerSession(session)`. أي حساب إيميله على شكل `0XXXXXXXXX@crystalstore.ly` يُعتبر زبون، ويترجّع لـ `index.html`، و`admin-login.html` يرفض دخوله. أي صفحة أدمن جديدة لازم تنسخ نفس الفحص.
  - الفحص هذا في الواجهة بس. **الحماية الحقيقية لازم تكون في RLS والـ RPC على Supabase**، يعني الكتابة على `products` و`cities` و`orders` لازم تكون مقصورة على حساب الأدمن.
- **XSS**: كل صفحة تستخدم `innerHTML` فيها دالة `esc()`. أي قيمة جاية من قاعدة البيانات أو الرابط أو localStorage لازم تتلف بـ `${esc(...)}` قبل ما تتحط في HTML. القيم اللي تنحط في رابط تتلف بـ `encodeURIComponent`.

## ملاحظات

- إرسال الإشعارات والتحقق من الحد الأدنى على السيرفر ما يصيروش في هذا الريبو. يصيروا من جهة Supabase.
- نصوص الواجهة موجّهة للمؤنث في أماكن (مثل "اختاري لون"، "مسجّلة باسم").
- صور المنتجات الناقصة تستخدم `via.placeholder.com`.
- عند التعديل: حافظ على `lang="ar" dir="rtl"`، وعلى نفس متغيرات CSS، وعلى نمط `supabaseClient` المحلي في كل صفحة.
