# Kiến Trúc & Kế Hoạch Kỹ Thuật MeshPulse

## 1. Mục tiêu Hệ thống & Môi trường Phát triển

**MeshPulse** là ứng dụng nhắn tin ngoại tuyến (*Off-grid Hybrid P2P & Multi-hop Mesh Messaging*) dành cho iOS, tự động thiết lập kết nối trực tiếp (**Direct Link / 1-Hop P2P**) khi hai thiết bị ở gần nhau và tự động mở rộng thành mạng lưới bắc cầu đa bước nhảy (**Relayed Route / Multi-Hop Mesh**) khi có từ 3 thiết bị trở lên, kèm cơ chế lưu-và-chuyển-tiếp (**DTN Store-and-Forward**) khi người nhận tạm thời nằm ngoài vùng phủ sóng.

* **Hệ điều hành phát triển:** Fedora Linux (`Swift 6.x` + `Swift Testing`).
* **Biên dịch chéo & Triển khai iOS:** `xtool` (`arm64-apple-ios` với Darwin SDK, ký chứng chỉ Apple ID và cài đặt qua cáp USB).
* **Giao diện:** 100% SwiftUI (*Tactical Telemetry Dark Mode*, tối ưu OLED, hỗ trợ Dynamic Type & Reduce Motion).
* **Nền tảng hệ thống Apple:** `MultipeerConnectivity` (BLE + Wi-Fi Direct/AWDL), `CryptoKit` (`Curve25519` + `HKDF-SHA256` + `ChaChaPoly`), `CoreLocation` (tọa độ GPS ngoại tuyến).

---

## 2. Phân tách Kiến trúc (Deep Modules & Seams)

Để tối đa hóa khả năng kiểm thử tự động ngay trên Linux mà không bị khóa chặt vào framework riêng của Darwin, dự án tách thành hai tầng rõ rệt trong `Package.swift` (vẫn giữ duy nhất 1 library product `MeshPulse` tương thích chuẩn `xtool`):

1. **`MeshCore` (Pure Swift 6, `Sendable`, 0 phụ thuộc UI/Darwin):**
   * Chứa toàn bộ mô hình miền (`NodeIdentity`, `MeshPacket`), bộ nhớ chống lặp giới hạn kích thước (`BoundedSeenCache`), bộ định tuyến hợp nhất (`MeshRouter`), hàng đợi DTN (`DTNOutbox`), giao diện mã hóa (`EnvelopeSealer`) và bộ mô phỏng mạng đa nút trong bộ nhớ (`SimulatedMeshNetwork`).
   * Cho phép chạy `swift test` trực tiếp trên Linux trong <1 giây để kiểm chứng định tuyến đa bước nhảy, chống lặp, `Spray-and-Wait`, `Epidemic Summary Vector` và `Topology Blocker`.
2. **`MeshPulse` (Ứng dụng SwiftUI & Platform Adapters trên iOS):**
   * `MultipeerTransport`: Bọc `MCSession`, `MCNearbyServiceAdvertiser`, `MCNearbyServiceBrowser`, giải quyết xung đột mời kết nối đối xứng (*Deterministic Tie-Breaking* theo `NodeID`), lọc `Topology Blocker` ngay tại ngõ vào (*Ingress Filtering*) và xuất luồng `AsyncStream<TransportEvent>` sang `@MainActor`.
   * `CryptoKitSealer`: Quản lý khóa `Curve25519` trong Keychain và mã hóa đầu-cuối `ChaChaPoly`.
   * `LocationProvider`: Thu thập tọa độ GPS ngoại tuyến cho tín hiệu khẩn cấp `SOS Signal`.
   * `MeshCoordinator` (`@Observable @MainActor`): Điều phối trạng thái cho 4 Tab giao diện và hỗ trợ chuyển đổi trực tiếp giữa **Mock Mode** (3 nút ảo) và **Live Radio Mode**.

---

## 3. Giao thức Gói tin & Định tuyến Lai

### 3.1. Cấu trúc `MeshPacket`
Mọi thông điệp truyền trên mạng đều đóng gói dưới dạng giá trị `Codable`, `Sendable`:
* `id: UUID` — Định danh duy nhất chống lặp vòng.
* `type: PacketType` — `.chat`, `.ack`, `.ping`, `.pong`, `.heartbeat`, `.summaryVector`, `.packetRequest`, `.sos`.
* `senderID: String` & `senderName: String` — Tách biệt định danh bất biến `NodeID` (khắc phục giới hạn iOS 16+ trả về tên chung `"iPhone"`) và biệt danh hiển thị.
* `targetID: String` — `"ALL"` cho Broadcast hoặc `NodeID` cụ thể cho Unicast.
* `routePath: [String]` — Danh sách thứ tự các nút đã đi qua.
* `ttl: Int` — Ngân sách bước nhảy còn lại (mặc định `4` cho chat, `6` cho SOS).
* `remainingCopies: Int` — Hạn ngạch bản sao còn lại cho thuật toán *Binary Spray-and-Wait*.
* `isEncrypted: Bool` & `payload: Data` — Dữ liệu rõ hoặc bản mã E2EE.

### 3.2. Ba Chiến lược Định tuyến & Cơ sở Học thuật
1. **Managed Flooding + Next-Hop Optimization (Mặc định):**
   * Nếu đích là láng giềng 1-hop trực tiếp $\rightarrow$ truyền thẳng Unicast (độ trễ thấp nhất).
   * Nếu biết láng giềng trung gian 2-hop qua bản tin `.heartbeat` $\rightarrow$ định tuyến đích danh qua trạm đó.
   * Ngược lại $\rightarrow$ phát tán có kiểm soát qua `BoundedSeenCache` (vòng đệm 2.048 ID) và giảm `ttl`. Chỉ gói Unicast mới phát sinh `ACK` ngược để tránh bão gói tin (*ACK Storm*).
2. **Binary Spray and Wait** *(Spyropoulos et al., WDTN 2005)*:
   * Nút nguồn khởi tạo $L$ bản sao (`remainingCopies`). Khi gặp nút trung gian chưa có gói tin, nút giữ chuyển giao $\lfloor L/2 \rfloor$ bản sao và giữ lại $\lceil L/2 \rceil$. Khi còn `1` bản sao, nút chỉ trao trực tiếp cho đích đến.
3. **Epidemic Routing với Summary Vector** *(Vahdat & Becker, 2000)*:
   * Khi hai nút thiết lập kết nối, chúng trao đổi `.summaryVector` chứa danh sách ID gói tin đang lưu trong `DTN Outbox`, đối chiếu phần thiếu để gửi `.packetRequest` và đồng bộ bù có chọn lọc.
4. **Tối ưu hóa phiên kết nối AWDL/BLE** *(Stute et al., CoNEXT 2018)*:
   * Duy trì số kết nối trực tiếp mỗi `MCSession` dưới ngưỡng bão hòa ($\le 7$ peers) và phân xử lời mời một chiều theo thứ tự từ điển `NodeID`.

---

## 4. Thiết kế Giao diện 4 Tabs (*Tactical Telemetry Dark Mode*)

* **Top Status Header (`safeAreaInset`):** Đèn báo `🟢 P2P | 🟠 Mesh`, tên định danh thiết bị hiện tại và nút `[🚨 SOS]` nhấn giữ 1.5s chống chạm nhầm.
* **Tab 1 — `📡 Mạng lưới`:** Đồ thị thời gian thực vẽ bằng `SwiftUI Canvas` (nét liền xanh `#10B981` cho 1-Hop, nét đứt cam `#F59E0B` cho Multi-Hop) + danh sách thẻ thiết bị kèm đo `[⚡ Ping]` RTT và mở nhanh chat 1-1.
* **Tab 2 — `🌐 Kênh Chung`:** Phòng chat toàn mạng hiển thị nhãn `Hop-Path Badge` dưới từng tin nhắn và chia sẻ nhanh tọa độ GPS.
* **Tab 3 — `🔒 Cá nhân`:** Trò chuyện 1-1 mã hóa đầu-cuối (`Curve25519` + `ChaChaPoly`, đối chiếu vân tay khóa) kết hợp tab quản lý `DTN Outbox` (`#6366F1`).
* **Tab 4 — `🛠️ Mesh Lab`:** Chuyển đổi Mock/Live Mode, ma trận công tắc **Topology Blocker** giả lập khuất sóng ngay trên bàn làm việc, bộ chọn thuật toán định tuyến, 4 thẻ đo kiểm Telemetry (`TX`, `Relayed`, `Dropped Duplicates`, `Avg RTT`) và trình soi gói tin JSON (`Packet Log`).
