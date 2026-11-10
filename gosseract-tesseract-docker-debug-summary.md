# Gosseract + Tesseract + Docker: Debugging Summary

## 1. Bối cảnh

Ứng dụng Go sử dụng `github.com/otiai10/gosseract` thông qua CGO để gọi
Tesseract OCR.

Dockerfile dùng multi-stage build: - **Builder:** cài package
development để compile Go application. - **Runtime:** cài Tesseract và
shared libraries cần thiết để chạy binary.

Vấn đề xuất hiện khi Builder và Runtime dùng distro hoặc repository khác
nhau, dẫn đến Tesseract/Leptonica có phiên bản và SONAME không tương
thích.

## 2. Lỗi gặp phải

Khi chạy application trong Runtime:

``` text
error while loading shared libraries:
libleptonica.so.6: cannot open shared object file
```

Ubuntu 20.04 cài Tesseract từ PPA lại có dependency tới `liblept.so.5`.

Kiểm tra:

``` bash
apt-cache depends libtesseract5
```

Kết quả cho thấy `libtesseract5` phụ thuộc `liblept5`.

## 3. Phân tích nguyên nhân

### 3.1 Binary yêu cầu shared library nào?

``` bash
readelf -d app | grep NEEDED
```

Binary có các dependency đáng chú ý:

``` text
libleptonica.so.6
libtesseract.so.5
```

Nghĩa là binary yêu cầu đúng SONAME `libleptonica.so.6`.

### 3.2 Runtime có resolve được dependency không?

``` bash
ldd app
```

Trên Ubuntu 20.04:

``` text
libleptonica.so.6 => not found
libtesseract.so.5 => /lib/x86_64-linux-gnu/libtesseract.so.5
liblept.so.5 => /lib/x86_64-linux-gnu/liblept.so.5
```

Trên Debian Trixie, các dependency tương ứng được resolve thành công.

### 3.3 Vì sao `liblept.so.5` không thay thế được `libleptonica.so.6`?

Đây là hai SONAME khác nhau:

-   `liblept.so.5`: shared library Leptonica với SONAME version 5.
-   `libleptonica.so.6`: shared library mà binary yêu cầu với SONAME
    version 6.

Không thể mặc định xem chúng là cùng một thư viện hoặc tương thích ABI.
Runtime có `liblept.so.5` không đáp ứng yêu cầu `libleptonica.so.6` của
binary.

## 4. Hai cơ chế dependency cần phân biệt

  -----------------------------------------------------------------------
  Cơ chế                  Công cụ                 Vai trò
  ----------------------- ----------------------- -----------------------
  Package dependency      APT                     Cài package phụ thuộc
                                                  của package được yêu
                                                  cầu

  Shared library          Linux dynamic linker    Tìm shared library mà
  resolution                                      executable hoặc `.so`
                                                  yêu cầu
  -----------------------------------------------------------------------

Ví dụ, APT có thể cài thành công:

``` text
tesseract-ocr
└── libtesseract5
    └── liblept5
```

Nhưng khi chạy application, dynamic linker vẫn có thể báo thiếu
`libleptonica.so.6`.

**APT cài package thành công không đồng nghĩa binary có đủ shared
library để chạy.**

## 5. Hướng khắc phục

### Khuyến nghị: đồng bộ Builder và Runtime

Cách đơn giản và an toàn nhất là dùng cùng distro và hệ sinh thái
package tương thích ở cả hai stage.

Ví dụ sử dụng Debian Trixie:

``` dockerfile
FROM golang:1.26.2-trixie AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config \
    libtesseract-dev \
    libleptonica-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=1 go build -o /app/app .

FROM debian:trixie-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    tesseract-ocr \
    tesseract-ocr-eng \
    tesseract-ocr-vie \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /app/app /app/app

CMD ["/app/app"]
```

`libtesseract-dev` và `libleptonica-dev` phục vụ compile nên thường chỉ
cần ở Builder. Runtime cần shared libraries tương ứng; cài
`tesseract-ocr` sẽ kéo dependency package cần thiết theo repository của
distro.

Language data như `tesseract-ocr-eng` và `tesseract-ocr-vie` cần được
cài nếu ứng dụng gọi `SetLanguage("eng", "vie")`.

### Nếu bắt buộc dùng Ubuntu 20.04

Có hai hướng:

1.  Dùng Ubuntu 20.04 cho cả Builder và Runtime, build với phiên bản
    Tesseract/Leptonica tương thích với package có trong Runtime.
2.  Tự build hoặc đóng gói đầy đủ Tesseract và Leptonica với shared
    libraries/SONAME tương thích, rồi cung cấp chúng trong Runtime.

Không nên tạo symlink từ `liblept.so.5` sang `libleptonica.so.6` để chữa
lỗi. Khác SONAME không đảm bảo tương thích ABI.

## 6. `TESSDATA_PREFIX` và language data

Trong môi trường Debian Trixie đang kiểm tra:

``` bash
TESSDATA_PREFIX=/usr/share/tesseract-ocr/5/tessdata
```

File language data tồn tại:

``` text
/usr/share/tesseract-ocr/5/tessdata/eng.traineddata
```

Lệnh:

``` bash
tesseract --list-langs
```

trả về:

``` text
List of available languages in "/usr/share/tesseract-ocr/5/tessdata/" (3):
eng
osd
vie
```

Điều này xác nhận Tesseract CLI tìm thấy language data `eng`, `osd`,
`vie` trong môi trường được kiểm tra. Đây là kiểm tra language data,
không thay thế việc kiểm tra shared library của Go binary hoặc chạy OCR
thực tế qua Gosseract.

## 7. Build thành công có đảm bảo app chạy được không?

**Không.** Cần phân biệt ba giai đoạn:

  -----------------------------------------------------------------------
  Giai đoạn                           Điều được xác nhận
  ----------------------------------- -----------------------------------
  `go build` thành công               Compiler/linker tạo được binary
                                      trong Builder

  Docker image build thành công       Các bước trong Dockerfile hoàn tất

  Application chạy thành công         Runtime resolve được shared
                                      libraries và dependency cần thiết;
                                      ứng dụng hoạt động khi thực thi
  -----------------------------------------------------------------------

Ví dụ: Builder có `libleptonica.so.6`, nhưng Runtime chỉ có
`liblept.so.5`. `go build` vẫn có thể thành công, nhưng app có thể lỗi
ngay khi khởi động.

### Quy trình kiểm tra đề xuất

**Bước 1 --- Kiểm tra binary cần thư viện nào:**

``` bash
readelf -d ./app | grep NEEDED
```

**Bước 2 --- Kiểm tra dependency trong Runtime container:**

``` bash
docker run --rm --entrypoint sh your-image -c 'ldd /app/app'
```

Kiểm tra không có dòng `not found`.

**Bước 3 --- Kiểm tra thư viện hệ thống:**

``` bash
ldconfig -p | grep -E 'lept|tesseract'
```

**Bước 4 --- Kiểm tra language data:**

``` bash
tesseract --list-langs
```

**Bước 5 --- Chạy ứng dụng và gửi request OCR thực tế.**

`ldd` xác nhận dynamic linker có thể tìm thấy shared libraries được liệt
kê, nhưng chưa chứng minh toàn bộ chức năng OCR hoạt động đúng. Cần kiểm
tra bằng request thực tế qua Gosseract.

## 8. Các lệnh debug tham khảo

  ---------------------------------------------------------------------------------------------------
  Mục đích                            Command
  ----------------------------------- ---------------------------------------------------------------
  Xem binary yêu cầu shared library   `readelf -d app \| grep NEEDED`
  nào                                 

  Kiểm tra runtime resolve dependency `ldd app`

  Xem shared library đã đăng ký       `ldconfig -p \| grep lept`

  Tìm file `.so` thực tế              `find /usr -name 'liblept*.so*' -o -name 'libleptonica*.so*'`

  Xem package phụ thuộc               `apt-cache depends tesseract-ocr`

  Xem nguồn và phiên bản package      `apt-cache policy libtesseract5`

  Mô phỏng package sẽ cài             `apt-get -s install tesseract-ocr`

  Xem dependency của shared library   `readelf -d /path/to/libtesseract.so.5 \| grep NEEDED`

  Kiểm tra ngôn ngữ Tesseract nhận    `tesseract --list-langs`
  diện                                
  ---------------------------------------------------------------------------------------------------

## 9. Kết luận

Nguyên nhân cốt lõi là sự không tương thích giữa shared library mà
binary được build yêu cầu và shared library có trong Runtime.

Nguyên tắc cần nhớ khi debug Docker multi-stage với Go + CGO:

> Builder quyết định binary cần những shared library nào. Runtime phải
> cung cấp đúng các shared library tương thích đó. Build thành công và
> APT cài package thành công đều chưa đủ để đảm bảo application chạy
> được.

**Trạng thái:** Đã xác định nguyên nhân và hướng khắc phục. Chưa có kết
quả xác nhận trong nội dung trao đổi rằng phương án cuối cùng đã được áp
dụng và kiểm thử thành công end-to-end.
