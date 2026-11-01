# MeshPulse

**Hybrid P2P & Multi-Hop Off-Grid Mesh Messaging for iOS** — phát triển bằng **Swift 6 + SwiftUI** và biên dịch chéo trực tiếp trên **Fedora Linux** với [`xtool`](https://xtool.sh).

## Tính năng cốt lõi

- **Zero-Config Discovery (`MultipeerConnectivity`):** Tự động khám phá và thiết lập phiên kết nối qua BLE + Wi-Fi Direct / AWDL với cơ chế phân xử lời mời chống xung đột (*Deterministic Tie-Breaking*).
- **Bộ định tuyến Lai (`MeshRouter`):** Tự động gửi trực tiếp 1-hop (**Direct Link**) khi ở gần hoặc bắc cầu đa bước nhảy (**Relayed Route**) qua thiết bị trung gian kèm bộ đệm chống lặp `BoundedSeenCache`.
- **3 Thuật toán Định tuyến MANET / DTN:** Chuyển đổi trực tiếp giữa *Managed Flooding*, *Binary Spray-and-Wait* và *Epidemic Summary-Vector Sync* (Store-and-Forward `DTN Outbox`).
- **Mã hóa Đầu-Cuối (`CryptoKit` E2EE):** Thỏa thuận khóa `Curve25519` + `HKDF-SHA256` và mã hóa `ChaChaPoly` cho tin nhắn 1-1 để các trạm trung chuyển không thể đọc nội dung.
- **Mesh Lab & Mock Mode:** Giả lập mạng 3 thiết bị ngay trên 1 máy và hỗ trợ **Topology Blocker** (chặn kết nối trực tiếp bằng phần mềm ở tầng ingress) để kiểm thử bắc cầu đa bước nhảy ngay trên bàn làm việc.
- **Tín hiệu Khẩn cấp (`SOS Signal`):** Phát quảng bá ưu tiên cao kèm tọa độ GPS ngoại tuyến (`CoreLocation`).

## Cấu trúc Thư mục

```text
MeshPulse/
├── Assets/                # Thư mục hình ảnh tĩnh & icon app (AppIcon, mesh.png)
├── Package.swift          # Swift 6 manifest (MeshCore, MeshPulse, MeshCoreTests)
├── xtool.yml              # Cấu hình bundleID & Info.plist cho xtool
├── Info.plist             # Quyền Local Network, Bonjour, Bluetooth & Location
├── GLOSSARY.md            # Từ điển thuật ngữ miền (Domain Model)
├── docs/
│   └── ARCHITECTURE.md    # Đặc tả kiến trúc & giao thức chi tiết
├── Sources/
│   ├── MeshCore/          # Lõi định tuyến, DTN & mô phỏng (chạy native trên Linux & iOS)
│   └── MeshPulse/         # Giao diện SwiftUI 4 Tabs & iOS Adapters (Multipeer, CryptoKit, GPS)
└── Tests/
    └── MeshCoreTests/     # Bộ kiểm thử Swift Testing cho MeshCore trên Linux
```

## Hướng dẫn Phát triển & Kiểm thử trên Fedora Linux

### 1. Chạy Unit & Multi-Node Simulation Tests (Native Linux)
```bash
swift test
```

### 2. Biên dịch kiểm tra gói ứng dụng iOS (`arm64-apple-ios`)
```bash
xtool dev build
```

### 3. Ký chứng chỉ & Cài đặt trực tiếp lên iPhone qua USB
```bash
xtool dev
```

## Tài liệu Tham khảo Học thuật

1. Vahdat, A., & Becker, D. (2000). *A Routing Scheme for Partially Connected Ad Hoc Networks* (Epidemic Routing). Duke University CS-2000-06.
2. Spyropoulos, T., Psounis, K., & Raghavendra, C. S. (2005). *Spray and Wait: An Efficient Routing Scheme for Intermittently Connected Mobile Networks*. ACM SIGCOMM WDTN.
3. Perkins, C. E., & Belding-Royer, E. M. (1999). *Ad-hoc On-Demand Distance Vector Routing* (RFC 3561).
4. Stute, M., Kreitschmann, D., & Hollick, M. (2018). *One Protocol to Rule Them All: Wireless Pocket-Switched Networks using AWDL*. ACM CoNEXT.
