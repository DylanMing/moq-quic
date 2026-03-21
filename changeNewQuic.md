# quic-go v0.45.1 → v0.59.0 升级变更记录

## 概述

本文档记录了将 moq-go 项目从 quic-go v0.45.1 升级到 v0.59.0 过程中所做的代码修改。

## 版本信息

- **Go 版本**: 1.24
- **quic-go**: v0.59.0
- **qpack**: v0.6.0

## 主要 API 变更

### 1. 接口类型改为结构体指针

quic-go v0.59.0 将接口类型改为结构体指针类型：

| 旧类型 | 新类型 |
|--------|--------|
| `quic.Connection` | `*quic.Conn` |
| `quic.Stream` | `*quic.Stream` |
| `quic.SendStream` | `*quic.SendStream` |
| `quic.ReceiveStream` | `*quic.ReceiveStream` |

### 2. qpack API 变更

| 旧 API | 新 API |
|--------|--------|
| `qpack.NewDecoder(nil)` | `qpack.NewDecoder()` |
| `decoder.DecodeFull(data)` | `decoder.Decode(data)` 返回 `DecodeFunc`，需循环调用直到 `io.EOF` |

## 修改的文件列表

### 1. go.mod

**路径**: `/Users/ming/Documents/moq-go/go.mod`

**修改内容**: 更新依赖版本

```diff
-go 1.21
+go 1.24

require (
-	github.com/quic-go/quic-go v0.45.1
-	github.com/quic-go/qpack v0.5.0
+	github.com/quic-go/quic-go v0.59.0
+	github.com/quic-go/qpack v0.6.0
	github.com/rs/zerolog v1.33.0
)
```

---

### 2. moqt/moqtsession.go

**路径**: `/Users/ming/Documents/moq-go/moqt/moqtsession.go`

**修改内容**: 更新 MOQTConnection 接口使用指针类型

```diff
 type MOQTConnection interface {
-	AcceptStream(context context.Context) (quic.Stream, error)
-	AcceptUniStream(context context.Context) (quic.ReceiveStream, error)
+	AcceptStream(context context.Context) (*quic.Stream, error)
+	AcceptUniStream(context context.Context) (*quic.ReceiveStream, error)
 	CloseWithError(quic.ApplicationErrorCode, string) error
-	OpenUniStreamSync(ctx context.Context) (quic.SendStream, error)
-	OpenUniStream() (quic.SendStream, error)
-	OpenStream() (quic.Stream, error)
+	OpenUniStreamSync(ctx context.Context) (*quic.SendStream, error)
+	OpenUniStream() (*quic.SendStream, error)
+	OpenStream() (*quic.Stream, error)
 }
```

---

### 3. moqt/controlstream.go

**路径**: `/Users/ming/Documents/moq-go/moqt/controlstream.go`

**修改内容**: 更新 ControlStream 结构体使用指针类型

```diff
 type ControlStream struct {
 	*MOQTSession
-	stream          quic.Stream
+	stream          *quic.Stream
 	ishandshakedone bool
 }

-func NewControlStream(session *MOQTSession, stream quic.Stream) *ControlStream {
+func NewControlStream(session *MOQTSession, stream *quic.Stream) *ControlStream {
```

---

### 4. moqt/moqlistener.go

**路径**: `/Users/ming/Documents/moq-go/moqt/moqlistener.go`

**修改内容**: 更新函数参数类型

```diff
-func (listener MOQTListener) handleMOQ(conn quic.Connection) {
+func (listener MOQTListener) handleMOQ(conn *quic.Conn) {

-func (listener MOQTListener) handleWebTransport(conn quic.Connection) {
+func (listener MOQTListener) handleWebTransport(conn *quic.Conn) {
```

---

### 5. moqt/pubstream.go

**路径**: `/Users/ming/Documents/moq-go/moqt/pubstream.go`

**修改内容**: 更新变量类型

```diff
-	var unistream quic.SendStream
+	var unistream *quic.SendStream
```

---

### 6. moqt/wire/stream.go

**路径**: `/Users/ming/Documents/moq-go/moqt/wire/stream.go`

**修改内容**: 更新 MOQTStream 接口中 Pipe 方法的签名

```diff
 type MOQTStream interface {
 	// ... other methods
-	Pipe(int, quic.SendStream) (int, error)
+	Pipe(int, *quic.SendStream) (int, error)
 	// ... other methods
 }
```

---

### 7. moqt/wire/groupstream.go

**路径**: `/Users/ming/Documents/moq-go/moqt/wire/groupstream.go`

**修改内容**: 更新 Pipe 方法签名

```diff
-func (gs *GroupStream) Pipe(index int, stream quic.SendStream) (int, error) {
+func (gs *GroupStream) Pipe(index int, stream *quic.SendStream) (int, error) {
```

---

### 8. moqt/wire/trackstream.go

**路径**: `/Users/ming/Documents/moq-go/moqt/wire/trackstream.go`

**修改内容**: 更新 Pipe 方法签名

```diff
-func (ts *TrackStream) Pipe(index int, stream quic.SendStream) (int, error) {
+func (ts *TrackStream) Pipe(index int, stream *quic.SendStream) (int, error) {
```

---

### 9. h3/headerframe.go

**路径**: `/Users/ming/Documents/moq-go/h3/headerframe.go`

**修改内容**: 更新 qpack API 使用方式

```diff
 	decoder := qpack.NewDecoder()
-	decodeFunc := decoder.Decode(data)
-
-	hfs, err := decodeFunc()
-	if err != nil {
-		log.Debug().Msgf("[Error Parsing HFs][Data - %s]", string(data))
-		return err
-	}
-
-	hframe.hfs = hfs
+	decodeFunc := decoder.Decode(data)
+
+	var hfs []qpack.HeaderField
+	for {
+		hf, err := decodeFunc()
+		if err == io.EOF {
+			break
+		}
+		if err != nil {
+			log.Debug().Msgf("[Error Parsing HFs][Data - %s]", string(data))
+			return err
+		}
+		hfs = append(hfs, hf)
+	}
+
+	hframe.hfs = hfs
```

---

### 10. h3/responsewriter.go

**路径**: `/Users/ming/Documents/moq-go/h3/responsewriter.go`

**修改内容**: 更新函数参数类型

```diff
-func NewResponseWriter(stream quic.Stream) *ResponseWriter {
+func NewResponseWriter(stream *quic.Stream) *ResponseWriter {
```

---

### 11. wt/wtsession.go

**路径**: `/Users/ming/Documents/moq-go/wt/wtsession.go`

**修改内容**: 更新所有 quic 相关类型

```diff
 type WTSession struct {
 	quic.Stream
-	quicConn       quic.Connection
+	quicConn       *quic.Conn
 	ResponseWriter *h3.ResponseWriter
 	context        context.Context
-	uniStreamsChan chan quic.ReceiveStream
+	uniStreamsChan chan *quic.ReceiveStream
 }

-func UpgradeWTS(quicConn quic.Connection) (*WTSession, *http.Request, error) {
+func UpgradeWTS(quicConn *quic.Conn) (*WTSession, *http.Request, error) {

 func (wts *WTSession) AcceptStream(ctx context.Context) (quic.Stream, error) {
-	return nil, err
+	return stream, err
 }
```

更新了以下方法的返回类型为指针类型：
- `AcceptStream` → `(*quic.Stream, error)`
- `AcceptUniStream` → `(*quic.ReceiveStream, error)`
- `OpenUniStreamSync` → `(*quic.SendStream, error)`
- `OpenStream` → `(*quic.Stream, error)`
- `OpenUniStream` → `(*quic.SendStream, error)`

---

## 测试结果

### 连接迁移测试

使用 `test_migration.sh` 脚本进行测试：

**TEST 1: Publisher 连接迁移**
- 中断前收到: 137 个 groups
- 中断后收到: 367 个 groups
- ✅ **测试通过**

**TEST 2: Subscriber 连接迁移**
- 中断前收到: 143 个 groups
- 中断后收到: 375 个 groups
- ✅ **测试通过**

---

## 总结

本次升级主要涉及类型系统的大规模变更，将接口类型改为结构体指针类型。这是 quic-go v0.50+ 版本的主要 API 变化。升级后项目成功编译并通过连接迁移测试。
