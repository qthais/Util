# Gosseract + Tesseract + Docker: Troubleshooting Summary

## 1. Bối cảnh

Ứng dụng Go sử dụng `github.com/otiai10/gosseract` để gọi Tesseract OCR
thông qua CGO. Dockerfile multi-stage ban đầu sử dụng hai môi trường
khác nhau:

-   Builder: `golang:1.26.2`
-   Runtime: `ubuntu:20.04`

### Builder

``` dockerfile
FROM golang:1.26.2 AS builder

RUN apt-get update && apt-get install -y \
    tesseract-ocr \
    libtesseract-dev \
    pkg-config

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=1 go build -o app .
```

### Runtime

``` dockerfile
FROM ubuntu:20.04

RUN apt-get update && apt-get install -y \
    software-properties-common \
    && add-apt-repository -y ppa:alex-p/tesseract-ocr5 \
    && apt-get update \
    && apt-get install -y tesseract-ocr

WORKDIR /app

COPY --from=builder /app/app .

CMD ["./app"]
```

Mục tiêu là build ứng dụng Gosseract ở Builder, sau đó chạy binary trên
Ubuntu 20.04.

## 2. Lỗi gặp phải

Khi chạy application trong Runtime:

``` bash
./app
```

xuất hiện lỗi:

``` text
error while loading shared libraries:
libleptonica.so.6: cannot open shared object file
```

Kiểm tra package:

``` bash
apt-cache policy libleptonica6
```

Kết quả:

``` text
N: Unable to locate package libleptonica6
```

Tiếp tục kiểm tra dependency của Tesseract:

``` bash
apt-cache depends libtesseract5
```

Kết quả:

``` text
libtesseract5
  Depends: libarchive13
  Depends: libc6
  Depends: libcurl4
  Depends: libgcc-s1
  Depends: liblept5
  Depends: libstdc++6
```

Điều này cho thấy package Tesseract trên Ubuntu 20.04 được cài từ PPA
phụ thuộc vào `liblept5`, không phải `libleptonica.so.6`.

## 3. Xác định dependency của binary và Runtime

### 3.1. Dùng `readelf` kiểm tra binary

``` bash
readelf -d app | grep NEEDED
```

Kết quả:

``` text
Shared library: [libleptonica.so.6]
Shared library: [libtesseract.so.5]
Shared library: [libstdc++.so.6]
Shared library: [libgcc_s.so.1]
Shared library: [libc.so.6]
```

Binary được build ra yêu cầu trực tiếp các shared library trên, trong đó
có `libleptonica.so.6` và `libtesseract.so.5`.

### 3.2. Dùng `ldd` kiểm tra khả năng resolve dependency

Trên Ubuntu 20.04:

``` text
libleptonica.so.6 => not found

libtesseract.so.5 => /lib/x86_64-linux-gnu/libtesseract.so.5

liblept.so.5 => /lib/x86_64-linux-gnu/liblept.so.5
```

Trên Debian Trixie, các dependency được resolve thành công, bao gồm:

``` text
libleptonica.so.6 => /lib/x86_64-linux-gnu/libleptonica.so.6

libtesseract.so.5 => /lib/x86_64-linux-gnu/libtesseract.so.5
```

Như vậy, binary được build trong môi trường có `libleptonica.so.6`,
nhưng Runtime Ubuntu 20.04 chỉ cung cấp `liblept.so.5` theo dependency
của package Tesseract được cài tại đó.

## 4. Vì sao có cả `liblept.so.5` và `libleptonica.so.6`?

Đây là hai tên shared library/SONAME khác nhau. Không thể mặc định xem
chúng là cùng một thư viện hoặc thay thế cho nhau.

Dependency trong Runtime Ubuntu 20.04 có thể hình dung như sau:

``` text
app
├── libleptonica.so.6       NOT FOUND
└── libtesseract.so.5       FOUND
    └── liblept.so.5        FOUND
```

Giải thích:

-   `app` yêu cầu `libleptonica.so.6` vì dependency này đã được ghi vào
    binary khi build.
-   `app` cũng yêu cầu `libtesseract.so.5`.
-   `libtesseract.so.5` trên Ubuntu 20.04 lại yêu cầu `liblept.so.5`.
-   Runtime tìm được `liblept.so.5`, nhưng điều đó không thay thế được
    yêu cầu `libleptonica.so.6` của application.

Vì vậy, dù Tesseract được cài thành công, application vẫn có thể không
khởi động được.

## 5. Hai cơ chế resolve dependency khác nhau

Cần phân biệt package dependency resolution và shared library
resolution:

  -----------------------------------------------------------------------
  Cơ chế                  Công cụ                 Resolve
  ----------------------- ----------------------- -----------------------
  Package dependency      APT                     Package → Package
  resolution                                      

  Shared library          Dynamic linker          Executable / `.so` →
  resolution                                      `.so`
  -----------------------------------------------------------------------

### 5.1. APT giải quyết package dependency

Ví dụ:

``` bash
apt install tesseract-ocr
```

APT tự động cài các package phụ thuộc, ví dụ:

``` text
tesseract-ocr
└── libtesseract5
    └── liblept5
```

APT cài package thành công không có nghĩa application chắc chắn chạy
được.

### 5.2. Dynamic linker giải quyết shared library dependency

Khi chạy:

``` bash
./app
```

Dynamic linker đọc danh sách `NEEDED` trong ELF binary và tìm các shared
library tương ứng trên hệ thống.

Dynamic linker không tự tải hoặc cài package khi không tìm thấy thư
viện. Nếu thiếu thư viện cần thiết, application có thể dừng ngay khi
khởi động với lỗi `cannot open shared object file`.

## 6. Hướng giải quyết

### 6.1. Khuyến nghị: đồng bộ Builder và Runtime

Đây là cách đơn giản và an toàn nhất: sử dụng cùng distro và hệ sinh
thái package tương thích cho cả hai stage.

Ví dụ, nếu chọn Debian Trixie:

**Builder:**

``` dockerfile
FROM golang:1.26.2 AS builder

RUN apt-get update && apt-get install -y \
    tesseract-ocr \
    libtesseract-dev \
    pkg-config

# Build application...
```

**Runtime:**

``` dockerfile
FROM debian:trixie-slim

RUN apt-get update && apt-get install -y \
    tesseract-ocr

WORKDIR /app

COPY --from=builder /app/app .

CMD ["./app"]
```

Cần đảm bảo Runtime cài đủ language data mà application sử dụng, nếu
chúng không được package `tesseract-ocr` cài sẵn.

### 6.2. Nếu bắt buộc sử dụng Ubuntu 20.04

Có hai hướng:

1.  Dùng Ubuntu 20.04 cho cả Builder và Runtime, build application dựa
    trên các phiên bản Tesseract/Leptonica tương thích với Ubuntu 20.04.
2.  Tự build hoặc đóng gói Tesseract và Leptonica với SONAME tương
    thích, sau đó cung cấp đầy đủ shared library tương ứng trong
    Runtime.

**Không nên chỉ tạo symlink từ `liblept.so.5` sang
`libleptonica.so.6`.** Hai SONAME khác nhau không đảm bảo ABI tương
thích; symlink không thể biến một ABI thành ABI khác.

## 7. Build thành công có đảm bảo application chạy được không?

Không. Build thành công không đồng nghĩa application chắc chắn chạy
được.

  -----------------------------------------------------------------------
  Giai đoạn                           Điều được xác nhận
  ----------------------------------- -----------------------------------
  `go build` thành công               Go compiler và linker tạo được
                                      binary

  Docker image build thành công       Các bước trong Dockerfile hoàn tất

  Application chạy thành công         Runtime có đủ shared library và
                                      dependency tương thích để khởi động
                                      và thực thi
  -----------------------------------------------------------------------

Ví dụ, binary yêu cầu:

``` text
libleptonica.so.6
libtesseract.so.5
```

Nếu Builder có `libleptonica.so.6` nhưng Runtime Ubuntu 20.04 chỉ có
`liblept.so.5`, thì `go build` vẫn có thể thành công. Tuy nhiên, khi
chạy application có thể gặp:

``` text
error while loading shared libraries:
libleptonica.so.6: cannot open shared object file
```

### Quy trình kiểm tra đề xuất

**Bước 1 --- Kiểm tra dependency được ghi trong binary:**

``` bash
readelf -d ./app | grep NEEDED
```

**Bước 2 --- Kiểm tra dependency có được resolve trong Runtime không:**

``` bash
ldd ./app
```

Nếu có dòng `not found`, Runtime chưa cung cấp được shared library mà
binary yêu cầu.

**Bước 3 --- Kiểm tra trực tiếp trong Runtime image:**

``` bash
docker run --rm --entrypoint sh your-image -c 'ldd /app/app'
```

**Bước 4 --- Chạy application và gửi request OCR thực tế.**

`ldd` chỉ xác nhận khả năng resolve shared library; nó không đảm bảo
toàn bộ chức năng OCR hoạt động đúng. Cần chạy thử application với input
thực tế để kiểm tra cả quá trình gọi Gosseract và Tesseract.

## 8. Các lệnh debug hữu ích

  --------------------------------------------------------------------------------------------
  Mục đích                            Command
  ----------------------------------- --------------------------------------------------------
  Xem binary cần shared library nào   `readelf -d app \| grep NEEDED`

  Kiểm tra Runtime resolve được       `ldd app`
  dependency không                    

  Xem shared library đã đăng ký       `ldconfig -p \| grep lept`

  Tìm file `.so` thực tế              `find /usr -name "liblept*.so*"`

  Xem package phụ thuộc               `apt-cache depends tesseract-ocr`

  Xem package đến từ repository nào   `apt-cache policy libtesseract5`

  Mô phỏng package sẽ cài             `apt-get -s install tesseract-ocr`

  Xem dependency của shared library   `readelf -d /path/to/libtesseract.so.5 \| grep NEEDED`
  --------------------------------------------------------------------------------------------

## 9. Kết luận

Vấn đề xuất phát từ sự không tương thích giữa shared library mà binary
được build yêu cầu và shared library có sẵn trong Runtime.

Điểm cần nhớ khi debug Docker multi-stage với Go, CGO và các thư viện
native:

> **Builder quyết định binary cần những shared library nào. Runtime phải
> cung cấp đúng các shared library tương thích đó. Việc APT cài package
> thành công hoặc Docker build thành công không đảm bảo binary có thể
> chạy.**

Vì vậy, ngoài việc kiểm tra `go build` và `docker build`, hãy kiểm tra
dependency của binary bằng `readelf`, kiểm tra khả năng resolve bằng
`ldd` ngay trong Runtime image, rồi chạy thử application với request OCR
thực tế.
