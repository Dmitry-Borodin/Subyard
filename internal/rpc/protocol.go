package rpc

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

const (
	ProtocolVersion = 1
	MaxFrameSize    = 1024 * 1024
)

type Request struct {
	Version     int             `json:"version"`
	Type        string          `json:"type"`
	ID          string          `json:"id"`
	Method      string          `json:"method,omitempty"`
	OperationID string          `json:"operationId,omitempty"`
	Params      json.RawMessage `json:"params,omitempty"`
}

type Response struct {
	Version  int             `json:"version"`
	Type     string          `json:"type"`
	ID       string          `json:"id,omitempty"`
	Sequence uint64          `json:"sequence,omitempty"`
	Revision uint64          `json:"revision,omitempty"`
	Event    string          `json:"event,omitempty"`
	Result   any             `json:"result,omitempty"`
	Error    *Error          `json:"error,omitempty"`
	Data     json.RawMessage `json:"data,omitempty"`
}

type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (fault *Error) Error() string { return fault.Code + ": " + fault.Message }

type Codec struct {
	reader *bufio.Reader
	writer io.Writer
}

func NewCodec(reader io.Reader, writer io.Writer) *Codec {
	return &Codec{reader: bufio.NewReader(reader), writer: writer}
}

func (codec *Codec) ReadRequest() (Request, error) {
	payload, err := codec.readPayload()
	if err != nil {
		return Request{}, err
	}
	var request Request
	if err := json.Unmarshal(payload, &request); err != nil {
		return Request{}, fmt.Errorf("decode RPC request: %w", err)
	}
	return request, nil
}

func (codec *Codec) ReadResponse() (Response, error) {
	payload, err := codec.readPayload()
	if err != nil {
		return Response{}, err
	}
	var response Response
	if err := json.Unmarshal(payload, &response); err != nil {
		return Response{}, fmt.Errorf("decode RPC response: %w", err)
	}
	return response, nil
}

func (codec *Codec) Write(value any) error {
	payload, err := json.Marshal(value)
	if err != nil {
		return fmt.Errorf("encode RPC frame: %w", err)
	}
	if len(payload) == 0 || len(payload) > MaxFrameSize {
		return fmt.Errorf("RPC frame size %d is outside the allowed range", len(payload))
	}
	header := make([]byte, 4)
	binary.BigEndian.PutUint32(header, uint32(len(payload)))
	if err := writeAll(codec.writer, header); err != nil {
		return fmt.Errorf("write RPC frame header: %w", err)
	}
	if err := writeAll(codec.writer, payload); err != nil {
		return fmt.Errorf("write RPC frame body: %w", err)
	}
	return nil
}

func (codec *Codec) readPayload() ([]byte, error) {
	header := make([]byte, 4)
	if _, err := io.ReadFull(codec.reader, header); err != nil {
		return nil, err
	}
	size := binary.BigEndian.Uint32(header)
	if size == 0 || size > MaxFrameSize {
		return nil, fmt.Errorf("RPC frame size %d is outside the allowed range", size)
	}
	payload := make([]byte, size)
	if _, err := io.ReadFull(codec.reader, payload); err != nil {
		return nil, fmt.Errorf("read RPC frame body: %w", err)
	}
	return payload, nil
}

func writeAll(writer io.Writer, payload []byte) error {
	for len(payload) != 0 {
		written, err := writer.Write(payload)
		if err != nil {
			return err
		}
		if written == 0 {
			return io.ErrShortWrite
		}
		payload = payload[written:]
	}
	return nil
}

func validateRequest(request Request) error {
	if request.Version != ProtocolVersion {
		return &Error{Code: "incompatible_version", Message: fmt.Sprintf("protocol version %d is not supported", request.Version)}
	}
	if request.ID == "" {
		return &Error{Code: "invalid_request", Message: "request ID is required"}
	}
	if len(request.Params) != 0 && !json.Valid(request.Params) {
		return &Error{Code: "invalid_request", Message: "params must be valid JSON"}
	}
	switch request.Type {
	case "request":
		if request.Method == "" {
			return &Error{Code: "invalid_request", Message: "method is required"}
		}
	case "cancel":
		if request.OperationID == "" {
			return &Error{Code: "invalid_request", Message: "operation ID is required"}
		}
	default:
		return &Error{Code: "invalid_request", Message: fmt.Sprintf("unknown frame type %q", request.Type)}
	}
	if containsSensitiveJSON(request.Params) {
		return &Error{Code: "secret_forbidden", Message: "secret-bearing fields are not accepted by RPC"}
	}
	return nil
}

func containsSensitiveJSON(raw json.RawMessage) bool {
	if len(raw) == 0 {
		return false
	}
	var value any
	decoder := json.NewDecoder(bytesReader(raw))
	decoder.UseNumber()
	if err := decoder.Decode(&value); err != nil {
		return false
	}
	return containsSensitive(value)
}

func containsSensitive(value any) bool {
	switch typed := value.(type) {
	case map[string]any:
		for key, child := range typed {
			normalized := normalizeKey(key)
			if normalized == "secret" || normalized == "password" || normalized == "token" ||
				normalized == "payload" || normalized == "privatekey" ||
				stringsContains(normalized, "secret") || stringsContains(normalized, "password") ||
				stringsContains(normalized, "token") || stringsContains(normalized, "privatekey") {
				return true
			}
			if containsSensitive(child) {
				return true
			}
		}
	case []any:
		for _, child := range typed {
			if containsSensitive(child) {
				return true
			}
		}
	}
	return false
}

func bytesReader(value []byte) io.Reader { return &sliceReader{value: value} }

type sliceReader struct{ value []byte }

func (reader *sliceReader) Read(target []byte) (int, error) {
	if len(reader.value) == 0 {
		return 0, io.EOF
	}
	count := copy(target, reader.value)
	reader.value = reader.value[count:]
	return count, nil
}

func normalizeKey(value string) string {
	result := make([]byte, 0, len(value))
	for index := 0; index < len(value); index++ {
		char := value[index]
		if char == '_' || char == '-' {
			continue
		}
		if char >= 'A' && char <= 'Z' {
			char += 'a' - 'A'
		}
		result = append(result, char)
	}
	return string(result)
}

func stringsContains(value, fragment string) bool {
	for index := 0; index+len(fragment) <= len(value); index++ {
		if value[index:index+len(fragment)] == fragment {
			return true
		}
	}
	return false
}

func asFault(err error) *Error {
	var fault *Error
	if errors.As(err, &fault) {
		return fault
	}
	if errors.Is(err, contextCanceled) || errors.Is(err, context.Canceled) {
		return &Error{Code: "cancelled", Message: "operation cancelled"}
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return &Error{Code: "deadline_exceeded", Message: "operation deadline exceeded"}
	}
	return &Error{Code: "internal", Message: err.Error()}
}

var contextCanceled = errors.New("operation cancelled")
