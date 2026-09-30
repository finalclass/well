// W3 Go client against the W3 Well server through the generated Proxy. It uses
// only the public ToDrut/FromDrut conversions of the generated package.

package main

import (
	"fmt"
	"net/http"
	"os"
	"strings"

	"generated_contracts/common"
	"generated_contracts/orders"
)

var pass, fail int

func check(name string, ok bool) {
	if ok {
		pass++
		fmt.Println("ok   " + name)
	} else {
		fail++
		fmt.Println("FAIL " + name)
	}
}

func echo(p orders.Proxy, id string) orders.ProxyResult[common.Thing] {
	ch := make(chan orders.ProxyResult[common.Thing], 1)
	p.Echo(common.Thing{ID: id}, func(r orders.ProxyResult[common.Thing]) { ch <- r })
	return <-ch
}

func status(base, token, method string) int {
	body := strings.NewReader("null")
	request, err := http.NewRequest("POST", base+"/rpc/Orders/"+method, body)
	if err != nil {
		return 0
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("X-Requested-With", "XMLHttpRequest")
	if token != "" {
		request.Header.Set("X-CSRF-Token", token)
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return 0
	}
	defer response.Body.Close()
	return response.StatusCode
}

func main() {
	base := "http://127.0.0.1:8478"
	if len(os.Args) > 1 {
		base = os.Args[1]
	}
	token := ""
	if len(os.Args) > 2 {
		token = os.Args[2]
	}
	proxy := orders.Proxy{BaseURL: base, CSRFToken: token}

	reserved := make(chan orders.ProxyResult[orders.ReserveResponse], 1)
	proxy.Reserve(orders.ReserveRequest{
		OwnerID:  "owner-1",
		Quantity: 9007199254740991,
		Thing:    common.Thing{ID: "t-1"},
		Tags:     []string{"a", "b"},
	}, func(r orders.ProxyResult[orders.ReserveResponse]) { reserved <- r })
	rr := <-reserved
	if rr.Err == nil {
		if value, ok := rr.Value.(orders.ReserveResponseReserved); ok {
			check("wide reserve",
				value.Value.Count == 9007199254740991 && value.Value.ID == "owner-1")
		} else {
			check("wide reserve", false)
		}
	} else {
		check("wide reserve", false)
	}

	echoed := echo(proxy, "cross-module")
	check("cross-module echo", echoed.Err == nil && echoed.Value.ID == "cross-module")

	numbersCh := make(chan orders.ProxyResult[common.Numbers], 1)
	proxy.Numbers(common.Numbers{
		Small:    7,
		Big:      9007199254740991,
		Negative: -9007199254740991,
		Ratio:    1.5,
		Unicode:  "Zażółć gęślą jaźń",
	}, func(r orders.ProxyResult[common.Numbers]) { numbersCh <- r })
	numbers := <-numbersCh
	check("wide numbers and unicode",
		numbers.Err == nil && numbers.Value.Big == 9007199254740991 &&
			numbers.Value.Negative == -9007199254740991 &&
			numbers.Value.Unicode == "Zażółć gęślą jaźń")

	legacy := echo(proxy, "legacy-error")
	check("2xx with error body",
		legacy.Err != nil && strings.Contains(legacy.Err.Error(), "legacy failure"))

	bad := echo(proxy, "bad-response")
	check("invalid response", bad.Err != nil)

	check("http status 404", status(base, token, "unknown_xyz") == 404)

	offline := echo(orders.Proxy{BaseURL: "http://127.0.0.1:9", CSRFToken: token}, "t")
	check("network error",
		offline.Err != nil && strings.Contains(strings.ToLower(offline.Err.Error()), "network"))

	fmt.Printf("\nW3 go client: %d passed, %d failed\n", pass, fail)
	if fail > 0 {
		os.Exit(1)
	}
}