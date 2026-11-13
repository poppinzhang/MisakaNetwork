package agent

import (
	"regexp"

	pb "github.com/MisakaNetwork/MisakaNetwork/gen/misaka/v1"
)

var paymentOrderID = regexp.MustCompile(`^[1-9][0-9]{0,79}$`)
var paymentCodeURL = regexp.MustCompile(`^(weixin://wxpay/bizpayurl\?pr=[A-Za-z0-9_-]{1,512}|https://qr\.alipay\.com/[A-Za-z0-9_-]{1,512})$`)

func confirmedOrder(out result) bool {
	return out.Status == "succeeded" || out.Status == "duplicate_order"
}

// orderPayment independently checks the runtime's optional payment fields.
// Unknown payment formats retain the canonical order page. URLs never enter
// messages/events, and the upstream-provided detail URL is not trusted.
func orderPayment(out result, capturedUnixMs int64) *pb.OrderPayment {
	if !confirmedOrder(out) || !paymentOrderID.MatchString(out.OrderID) {
		return nil
	}
	payment := &pb.OrderPayment{
		OrderId:        out.OrderID,
		OrderDetailUrl: "https://show.bilibili.com/platform/orderDetail.html?order_id=" + out.OrderID,
		CapturedUnixMs: capturedUnixMs,
	}
	if len(out.PaymentCodeURL) <= 2048 && paymentCodeURL.MatchString(out.PaymentCodeURL) {
		payment.PaymentCodeUrl = out.PaymentCodeURL
	}
	return payment
}
